//! Video use cases shared by the JSON API (`routes::videos`) and the web pages (`web`).
//! Handlers parse transport input; everything that touches storage or the database lives
//! here so both adapters enforce the same rules.
//!
//! Each database unit of work runs in one transaction under the caller's row-level-security
//! context: [`Scope::context`] for owners, [`Scope::share`] for viewers of a share link and
//! [`Context::maintenance`] for retention only.

use std::collections::HashMap;
use std::time::Duration;

use chrono::{Datelike, Utc};
use hmac::{Hmac, Mac};
use sha2::Sha256;
use uuid::Uuid;

use super::model::{Comment, ItemView, Reaction, Video};
use super::scope::{Scope, Visibility};
use crate::auth::{generate_slug, hash_password_blocking, verify_password_blocking};
use crate::db::{Context, Value, execute_in, placeholders, query_in};
use crate::error::{AppError, AppResult};
use crate::orm::{begin, is_unique_violation, orm_err};
use crate::repo::{now_ms, ts};
use crate::state::AppState;
use crate::vals;

/// S3 requires every part except the last to be at least 5 MiB.
pub const MIN_PART_BYTES: i64 = 5 * 1024 * 1024;
/// S3's largest part.
pub const MAX_PART_BYTES: i64 = 5 * 1024 * 1024 * 1024;
pub const MAX_PARTS: i32 = 10_000;
/// Part URLs requested in one call.
pub const MAX_PART_BATCH: usize = 100;
/// Longest part ETag accepted at completion, quotes excluded.
pub const MAX_ETAG_CHARS: usize = 64;
/// Body limit of `POST /v1/videos/{id}/complete`: a manifest of [`MAX_PARTS`] parts. One
/// compact entry with the longest accepted ETag is about 100 bytes; the rest is slack for
/// whitespace and the other fields.
pub const COMPLETE_BODY_LIMIT: usize = MAX_PARTS as usize * 160 + 64 * 1024;
pub const PART_URL_TTL: Duration = Duration::from_secs(3600);
pub const ASSET_PUT_TTL: Duration = Duration::from_secs(600);
/// Media URLs on the watch page; long enough for a long video to keep seeking.
pub const MEDIA_URL_TTL: Duration = Duration::from_secs(6 * 3600);
pub const SHORT_URL_TTL: Duration = Duration::from_secs(600);
pub const MAX_THUMBNAIL_BYTES: i64 = 2 * 1024 * 1024;
pub const MAX_TRANSCRIPT_BYTES: i64 = 1024 * 1024;
/// Uploads still pending after this long are aborted by the expire job.
pub const STALE_PENDING_MS: i64 = 24 * 3_600_000;
pub const MAX_TITLE_CHARS: usize = 200;
pub const MAX_COMMENT_CHARS: usize = 2000;
pub const MAX_NAME_CHARS: usize = 60;
/// Rendered on a watch page; older items stay stored but are not shown.
pub const MAX_LISTED: usize = 500;
pub const EMOJIS: [&str; 7] = ["👍", "❤️", "😂", "🎉", "😮", "🔥", "👀"];

pub const VIDEO_TYPES: [(&str, &str); 3] = [
    ("video/mp4", "mp4"),
    ("video/quicktime", "mov"),
    ("video/webm", "webm"),
];

pub fn video_ext(content_type: &str) -> Option<&'static str> {
    VIDEO_TYPES
        .iter()
        .find(|(t, _)| *t == content_type)
        .map(|(_, e)| *e)
}

pub fn share_url(st: &AppState, slug: &str) -> String {
    format!("{}/v/{slug}", st.config.public_base_url)
}

fn store_err(e: crate::storage::StoreError) -> AppError {
    AppError::Storage(e.0)
}

/// Trim, collapse to one line and cap; `None` when empty.
pub fn clean_line(s: &str, max: usize) -> Option<String> {
    let s: String = s
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .chars()
        .take(max)
        .collect();
    (!s.is_empty()).then_some(s)
}

/// Keep line breaks (comments), drop other control characters, cap length.
pub fn clean_text(s: &str, max: usize) -> Option<String> {
    let s: String = s
        .trim()
        .chars()
        .filter(|c| *c == '\n' || !c.is_control())
        .take(max)
        .collect();
    (!s.trim().is_empty()).then_some(s)
}

pub fn default_title(now_ms: i64) -> String {
    format!("Recording {}", ts(now_ms).format("%Y-%m-%d %H:%M UTC"))
}

fn base_key(user_id: &str, id: &str, now_ms: i64) -> String {
    let t = ts(now_ms);
    format!("v/{user_id}/{:04}/{:02}/{id}", t.year(), t.month())
}

fn valid_slug(slug: &str) -> bool {
    !slug.is_empty() && slug.len() <= 32 && slug.bytes().all(|b| b.is_ascii_alphanumeric())
}

/// Part ETags as S3, MinIO, R2 and Tigris return them (32 hex digits, quoted) and as the
/// in-memory store makes them: optionally quoted, 1..=[`MAX_ETAG_CHARS`] of `[A-Za-z0-9_-]`.
pub fn valid_etag(tag: &str) -> bool {
    let inner = tag
        .strip_prefix('"')
        .and_then(|t| t.strip_suffix('"'))
        .unwrap_or(tag);
    (1..=MAX_ETAG_CHARS).contains(&inner.len())
        && inner
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

/// Serializes one account's upload bookkeeping (creating uploads, reserving parts,
/// completing) inside `tx`, so the pending cap and the byte budgets hold under concurrent
/// requests. Released when `tx` ends.
async fn lock_uploads(tx: &mut dyn toasty::Executor, user_id: &str) -> AppResult<()> {
    execute_in(
        tx,
        "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
        &vals![format!("easyshot:uploads:{user_id}")],
    )
    .await?;
    Ok(())
}

/// Unfinished uploads that still count against the account (the expire job aborts older
/// ones, and their parts can no longer be requested).
async fn pending_uploads(tx: &mut dyn toasty::Executor, user_id: &str, now: i64) -> AppResult<i64> {
    Ok(query_in(
        tx,
        "SELECT COUNT(*) FROM videos WHERE user_id = $1 AND status = 'pending' AND created_at >= $2",
        &vals![user_id, now - STALE_PENDING_MS],
    )
    .await?
    .first()
    .map(|r| r.i64(0))
    .transpose()?
    .unwrap_or(0))
}

// ---------- lookup ----------

/// Resolve a share link for `scope` (RLS share path). Expired links resolve to `None`;
/// visibility is decided by the caller with [`Scope::access`].
pub async fn resolve_share_link(
    st: &AppState,
    scope: &Scope,
    slug: &str,
) -> AppResult<Option<Video>> {
    if !valid_slug(slug) {
        return Ok(None);
    }
    let mut db = st.orm().await?;
    let mut tx = begin(&mut db, &scope.share_lookup(slug)).await?;
    let v = Video::filter_by_slug(slug)
        .first()
        .exec(&mut tx)
        .await
        .map_err(orm_err)?;
    tx.commit().await.map_err(orm_err)?;
    Ok(v.filter(|v| v.expires_at > now_ms()))
}

// ---------- create and upload ----------

pub struct NewVideo {
    pub title: Option<String>,
    pub content_type: String,
}

pub async fn create(st: &AppState, scope: &Scope, input: NewVideo) -> AppResult<Video> {
    let user_id = scope.user_id.ok_or(AppError::Unauthorized)?;
    let content_type = input.content_type.trim().to_ascii_lowercase();
    let ext = video_ext(&content_type).ok_or(AppError::UnsupportedType)?;
    let now = now_ms();
    let title = input
        .title
        .as_deref()
        .and_then(|t| clean_line(t, MAX_TITLE_CHARS))
        .unwrap_or_else(|| default_title(now));
    let id = Uuid::new_v4().to_string();
    let user = user_id.to_string();
    let key = format!("{}.{ext}", base_key(&user, &id, now));
    let cap = st.config.max_pending_uploads;
    let mut db = st.orm().await?;
    // Refuse early, before creating a multipart upload; re-checked under the lock below.
    let mut tx = begin(&mut db, &scope.context()).await?;
    let pending = pending_uploads(&mut tx, &user, now).await?;
    tx.commit().await.map_err(orm_err)?;
    if pending >= cap {
        return Err(AppError::TooManyPendingUploads);
    }
    let upload_id = st
        .store
        .create_multipart(&key, &content_type)
        .await
        .map_err(store_err)?;
    let expires_at = now + st.config.video_retention_days * 86_400_000;
    let created: AppResult<Video> = async {
        for _ in 0..8 {
            let mut tx = begin(&mut db, &scope.context()).await?;
            // Count and insert under the account's upload lock: concurrent creates cannot
            // both see room for one more.
            lock_uploads(&mut tx, &user).await?;
            if pending_uploads(&mut tx, &user, now).await? >= cap {
                return Err(AppError::TooManyPendingUploads);
            }
            let created = toasty::create!(Video {
                id: id.clone(),
                kind: "video",
                user_id: user.clone(),
                workspace_id: None::<String>,
                slug: generate_slug(),
                title: title.clone(),
                status: "pending",
                object_key: key.clone(),
                upload_id: Some(upload_id.clone()),
                content_type: content_type.clone(),
                byte_size: 0,
                duration_ms: 0,
                width: None::<i64>,
                height: None::<i64>,
                thumbnail_key: None::<String>,
                transcript_key: None::<String>,
                visibility: Visibility::Link.as_str(),
                password_hash: None::<String>,
                created_at: now,
                updated_at: now,
                ready_at: None::<i64>,
                expires_at,
                uploaded_bytes: 0,
                recording_ended_at: None::<i64>,
            })
            .exec(&mut tx)
            .await;
            match created {
                Ok(v) => {
                    tx.commit().await.map_err(orm_err)?;
                    return Ok(v);
                }
                Err(e) if is_unique_violation(&e) => continue,
                Err(e) => return Err(orm_err(e)),
            }
        }
        Err(AppError::Internal("could not allocate slug".into()))
    }
    .await;
    if created.is_err() {
        let _ = st.store.abort_multipart(&key, &upload_id).await;
    }
    created
}

pub async fn presign_parts(
    st: &AppState,
    scope: &Scope,
    v: &Video,
    parts: &[(i32, i64)],
) -> AppResult<Vec<(i32, crate::storage::PresignedPut)>> {
    let upload_id = match (&v.upload_id, v.status.as_str()) {
        (Some(u), "pending") => u,
        _ => return Err(AppError::Invalid("upload already completed".into())),
    };
    let now = now_ms();
    if v.created_at < now - STALE_PENDING_MS {
        return Err(AppError::Invalid(
            "this upload has expired; share the recording again".into(),
        ));
    }
    if parts.is_empty() || parts.len() > MAX_PART_BATCH {
        return Err(AppError::Invalid(format!(
            "request between 1 and {MAX_PART_BATCH} parts"
        )));
    }
    let max_part = MAX_PART_BYTES.min(st.config.max_video_bytes);
    let mut seen = std::collections::HashSet::with_capacity(parts.len());
    for &(n, size) in parts {
        if !(1..=MAX_PARTS).contains(&n) || !seen.insert(n) {
            return Err(AppError::Invalid(format!(
                "part numbers must be distinct and between 1 and {MAX_PARTS}"
            )));
        }
        if size <= 0 {
            return Err(AppError::Invalid("part sizes must be positive".into()));
        }
        if size > max_part {
            return Err(AppError::TooLarge);
        }
    }
    reserve_parts(st, scope, v, parts, now).await?;
    let mut out = Vec::with_capacity(parts.len());
    for &(n, size) in parts {
        let put = st
            .store
            .presign_upload_part(&v.object_key, upload_id, n, size, PART_URL_TTL)
            .await
            .map_err(store_err)?;
        out.push((n, put));
    }
    Ok(out)
}

/// Record the byte size of each part before any URL is signed for it. A part's size is
/// fixed once reserved (asking again with the same size is fine), so the bytes in storage
/// never exceed the reservation; the video's parts stay within `max_video_bytes` and all of
/// the account's unfinished uploads within `max_pending_upload_bytes`.
async fn reserve_parts(
    st: &AppState,
    scope: &Scope,
    v: &Video,
    parts: &[(i32, i64)],
    now: i64,
) -> AppResult<()> {
    let mut db = st.orm().await?;
    let mut tx = begin(&mut db, &scope.context()).await?;
    lock_uploads(&mut tx, &v.user_id).await?;
    // Completion takes the same lock; once it has run there is nothing left to reserve.
    let still_pending = query_in(
        &mut tx,
        "SELECT 1 FROM videos WHERE id = $1 AND status = 'pending'",
        &vals![v.id.as_str()],
    )
    .await?;
    if still_pending.is_empty() {
        return Err(AppError::Invalid("upload already completed".into()));
    }
    let mut params: Vec<Value> = vec![v.id.as_str().into()];
    params.extend(parts.iter().map(|(n, _)| Value::from(*n)));
    let existing = query_in(
        &mut tx,
        &format!(
            "SELECT part_number, byte_size FROM upload_parts WHERE video_id = $1 AND part_number IN ({})",
            placeholders(2, parts.len())
        ),
        &params,
    )
    .await?;
    let mut reserved = HashMap::with_capacity(existing.len());
    for r in &existing {
        reserved.insert(r.i64(0)? as i32, r.i64(1)?);
    }
    let mut fresh = Vec::with_capacity(parts.len());
    for &(n, size) in parts {
        match reserved.get(&n) {
            Some(&s) if s != size => {
                return Err(AppError::Invalid(format!(
                    "part {n} was already requested with {s} bytes"
                )));
            }
            Some(_) => {}
            None => fresh.push((n, size)),
        }
    }
    if fresh.is_empty() {
        return Ok(());
    }
    let mut params: Vec<Value> = Vec::with_capacity(fresh.len() * 6);
    let rows: Vec<String> = fresh
        .iter()
        .enumerate()
        .map(|(i, &(n, size))| {
            params.extend([
                v.id.as_str().into(),
                n.into(),
                v.user_id.as_str().into(),
                v.workspace_id.as_deref().into(),
                size.into(),
                now.into(),
            ]);
            format!("({})", placeholders(i * 6 + 1, 6))
        })
        .collect();
    execute_in(
        &mut tx,
        &format!(
            "INSERT INTO upload_parts (video_id, part_number, user_id, workspace_id, byte_size, created_at) \
             VALUES {}",
            rows.join(", ")
        ),
        &params,
    )
    .await?;
    let sums = query_in(
        &mut tx,
        "SELECT COALESCE(SUM(p.byte_size) FILTER (WHERE p.video_id = $2), 0)::BIGINT, \
                COALESCE(SUM(p.byte_size), 0)::BIGINT \
         FROM upload_parts p JOIN videos v ON v.id = p.video_id \
         WHERE p.user_id = $1 AND v.status = 'pending' AND v.created_at >= $3",
        &vals![v.user_id.as_str(), v.id.as_str(), now - STALE_PENDING_MS],
    )
    .await?;
    let (video, account) = match sums.first() {
        Some(r) => (r.i64(0)?, r.i64(1)?),
        None => (0, 0),
    };
    if video > st.config.max_video_bytes || account > st.config.max_pending_upload_bytes {
        // Dropping the transaction rolls the reservation back.
        return Err(AppError::TooLarge);
    }
    tx.commit().await.map_err(orm_err)?;
    Ok(())
}

pub struct Completion {
    pub parts: Vec<(i32, String)>,
    pub duration_ms: Option<i64>,
    pub width: Option<i64>,
    pub height: Option<i64>,
}

/// Finish a recording's upload. Idempotent: a retry after the store already assembled the
/// object (the process or the database failed before the row became ready) finds the
/// upload gone, checks the object against the reserved sizes of the named parts and
/// finishes the transition.
pub async fn complete(st: &AppState, scope: &Scope, v: Video, c: Completion) -> AppResult<Video> {
    if v.status == "ready" {
        return Ok(v);
    }
    let upload_id = v
        .upload_id
        .clone()
        .ok_or_else(|| AppError::Invalid("no upload in progress".into()))?;
    let mut parts = c.parts;
    if parts.is_empty() || parts.len() > MAX_PARTS as usize {
        return Err(AppError::Invalid(format!(
            "list between 1 and {MAX_PARTS} parts"
        )));
    }
    parts.sort_by_key(|p| p.0);
    if parts.windows(2).any(|w| w[0].0 == w[1].0)
        || parts
            .iter()
            .any(|(n, tag)| !(1..=MAX_PARTS).contains(n) || !valid_etag(tag))
    {
        return Err(AppError::Invalid("invalid parts list".into()));
    }
    if c.width.is_some_and(|w| w <= 0) || c.height.is_some_and(|h| h <= 0) {
        return Err(AppError::Invalid("width/height must be positive".into()));
    }
    let reserved = reserved_parts(st, scope, &v.id).await?;
    let mut expected = 0;
    for (n, _) in &parts {
        expected += reserved.get(n).ok_or_else(|| {
            AppError::Invalid(format!("part {n} was never requested for this upload"))
        })?;
    }
    let recovering = match st
        .store
        .complete_multipart(&v.object_key, &upload_id, &parts)
        .await
    {
        Ok(()) => false,
        Err(e) if e.0.contains("NoSuchUpload") => true,
        Err(e) if e.0.contains("InvalidPart") || e.0.contains("EntityTooSmall") => {
            return Err(AppError::Invalid(format!(
                "upload could not be completed: {}",
                e.0
            )));
        }
        Err(e) => return Err(store_err(e)),
    };
    let meta = st.store.head(&v.object_key).await.map_err(store_err)?;
    let size = match meta {
        Some(m) if m.size == expected => m.size,
        // Just assembled from parts whose sizes were signed, yet not the reserved size: the
        // store let unreserved bytes in. Keep none of it.
        Some(m) if !recovering => {
            purge(st, &scope.context(), &v).await?;
            return Err(if m.size > st.config.max_video_bytes {
                AppError::TooLarge
            } else {
                AppError::NotUploaded
            });
        }
        // Aborted, never assembled, or assembled from other parts than these.
        _ => return Err(AppError::NotUploaded),
    };
    let now = now_ms();
    let duration = c.duration_ms.unwrap_or(0).clamp(0, 24 * 3_600_000);
    let mut db = st.orm().await?;
    let mut tx = begin(&mut db, &scope.context()).await?;
    lock_uploads(&mut tx, &v.user_id).await?;
    Video::update_by_id(&v.id)
        .status("ready")
        .upload_id(None::<String>)
        .byte_size(size)
        .duration_ms(duration)
        .width(c.width.or(v.width))
        .height(c.height.or(v.height))
        .ready_at(Some(now))
        .updated_at(now)
        .exec(&mut tx)
        .await
        .map_err(orm_err)?;
    // No longer pending: release the reservation.
    execute_in(
        &mut tx,
        "DELETE FROM upload_parts WHERE video_id = $1",
        &vals![v.id.as_str()],
    )
    .await?;
    tx.commit().await.map_err(orm_err)?;
    scope.managed(st, &v.id).await
}

/// Reserved size per part number of a pending upload.
async fn reserved_parts(st: &AppState, scope: &Scope, id: &str) -> AppResult<HashMap<i32, i64>> {
    let rows = st
        .db
        .scoped(scope.context())
        .query(
            "SELECT part_number, byte_size FROM upload_parts WHERE video_id = $1",
            &vals![id],
        )
        .await?;
    let mut out = HashMap::with_capacity(rows.len());
    for r in &rows {
        out.insert(r.i64(0)? as i32, r.i64(1)?);
    }
    Ok(out)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Asset {
    Thumbnail,
    Transcript,
}

impl Asset {
    pub fn content_type(self) -> &'static str {
        match self {
            Asset::Thumbnail => "image/jpeg",
            Asset::Transcript => "text/vtt",
        }
    }
    fn max(self) -> i64 {
        match self {
            Asset::Thumbnail => MAX_THUMBNAIL_BYTES,
            Asset::Transcript => MAX_TRANSCRIPT_BYTES,
        }
    }
    fn ext(self) -> &'static str {
        match self {
            Asset::Thumbnail => "jpg",
            Asset::Transcript => "vtt",
        }
    }
    /// The asset's deterministic object key.
    fn key(self, v: &Video) -> String {
        format!(
            "{}.{}",
            base_key(&v.user_id, &v.id, v.created_at),
            self.ext()
        )
    }
    fn published(self, v: &Video) -> Option<&str> {
        match self {
            Asset::Thumbnail => v.thumbnail_key.as_deref(),
            Asset::Transcript => v.transcript_key.as_deref(),
        }
    }
}

/// Presigned PUT for a poster frame or WebVTT transcript. Nothing is published until
/// [`complete_asset`] finds the object.
pub async fn presign_asset(
    st: &AppState,
    v: &Video,
    asset: Asset,
    byte_size: i64,
) -> AppResult<crate::storage::PresignedPut> {
    if byte_size <= 0 {
        return Err(AppError::Invalid("byte_size must be positive".into()));
    }
    if byte_size > asset.max() {
        return Err(AppError::TooLarge);
    }
    st.store
        .presign_put(
            &asset.key(v),
            asset.content_type(),
            byte_size,
            ASSET_PUT_TTL,
        )
        .await
        .map_err(store_err)
}

/// Publish an uploaded poster frame or transcript: the object must exist, fit the asset's
/// limit and have its content type. Setting the key notifies every open watch page.
pub async fn complete_asset(
    st: &AppState,
    scope: &Scope,
    v: &Video,
    asset: Asset,
) -> AppResult<Video> {
    let key = asset.key(v);
    let meta = st
        .store
        .head(&key)
        .await
        .map_err(store_err)?
        .ok_or(AppError::NotUploaded)?;
    let typed = meta
        .content_type
        .as_deref()
        .and_then(|t| t.split(';').next())
        .is_some_and(|t| t.trim().eq_ignore_ascii_case(asset.content_type()));
    let fits = (1..=asset.max()).contains(&meta.size);
    if !(typed && fits) {
        // Only a store that ignored the signed length and type lets this in. The object
        // replaced any earlier upload under the same key: delete it and unpublish.
        st.store
            .delete_many(std::slice::from_ref(&key))
            .await
            .map_err(store_err)?;
        if asset.published(v).is_some() {
            set_asset_key(st, scope, v, asset, None).await?;
        }
        return Err(AppError::NotUploaded);
    }
    set_asset_key(st, scope, v, asset, Some(key)).await?;
    scope.managed(st, &v.id).await
}

async fn set_asset_key(
    st: &AppState,
    scope: &Scope,
    v: &Video,
    asset: Asset,
    key: Option<String>,
) -> AppResult<()> {
    let mut db = st.orm().await?;
    let mut tx = begin(&mut db, &scope.context()).await?;
    let q = Video::update_by_id(&v.id).updated_at(now_ms());
    match asset {
        Asset::Thumbnail => q.thumbnail_key(key),
        Asset::Transcript => q.transcript_key(key),
    }
    .exec(&mut tx)
    .await
    .map_err(orm_err)?;
    tx.commit().await.map_err(orm_err)?;
    Ok(())
}

// ---------- owner edits ----------

#[derive(Default)]
pub struct Edit {
    pub title: Option<String>,
    pub visibility: Option<Visibility>,
    pub password: Option<String>,
}

pub async fn edit(st: &AppState, scope: &Scope, v: &Video, e: Edit) -> AppResult<Video> {
    let mut password_hash = None;
    let mut clear_password = false;
    if let Some(p) = e.visibility {
        match (p, e.password) {
            (Visibility::Password, Some(pw)) => {
                let n = pw.chars().count();
                if !(4..=128).contains(&n) {
                    return Err(AppError::Invalid(
                        "password must be between 4 and 128 characters".into(),
                    ));
                }
                password_hash = Some(hash_password_blocking(pw).await?);
            }
            (Visibility::Password, None) if v.password_hash.is_none() => {
                return Err(AppError::Invalid("choose a password".into()));
            }
            (Visibility::Password, None) => {}
            _ => clear_password = true,
        }
    }
    let title = match e.title {
        Some(t) => Some(
            clean_line(&t, MAX_TITLE_CHARS)
                .ok_or_else(|| AppError::Invalid("title must not be empty".into()))?,
        ),
        None => None,
    };
    let mut db = st.orm().await?;
    let mut tx = begin(&mut db, &scope.context()).await?;
    let mut q = Video::update_by_id(&v.id).updated_at(now_ms());
    if let Some(t) = title {
        q = q.title(t);
    }
    if let Some(p) = e.visibility {
        q = q.visibility(p.as_str());
    }
    if let Some(h) = password_hash {
        q = q.password_hash(Some(h));
    } else if clear_password {
        q = q.password_hash(None::<String>);
    }
    q.exec(&mut tx).await.map_err(orm_err)?;
    tx.commit().await.map_err(orm_err)?;
    scope.managed(st, &v.id).await
}

/// Delete objects, conversation and the row under `ctx` (the owner's, or maintenance).
/// Idempotent; storage first so a failure keeps the row for a retry.
pub async fn purge(st: &AppState, ctx: &Context, v: &Video) -> AppResult<()> {
    if let Some(u) = &v.upload_id {
        st.store
            .abort_multipart(&v.object_key, u)
            .await
            .map_err(store_err)?;
    }
    let mut keys = vec![v.object_key.clone()];
    keys.extend(v.thumbnail_key.clone());
    keys.extend(v.transcript_key.clone());
    st.store.delete_many(&keys).await.map_err(store_err)?;
    let mut db = st.orm().await?;
    let mut tx = begin(&mut db, ctx).await?;
    Comment::filter_by_item_id(&v.id)
        .delete()
        .exec(&mut tx)
        .await
        .map_err(orm_err)?;
    Reaction::filter_by_item_id(&v.id)
        .delete()
        .exec(&mut tx)
        .await
        .map_err(orm_err)?;
    ItemView::filter_by_item_id(&v.id)
        .delete()
        .exec(&mut tx)
        .await
        .map_err(orm_err)?;
    execute_in(
        &mut tx,
        "DELETE FROM upload_parts WHERE video_id = $1",
        &vals![v.id.as_str()],
    )
    .await?;
    Video::filter_by_id(&v.id)
        .delete()
        .exec(&mut tx)
        .await
        .map_err(orm_err)?;
    tx.commit().await.map_err(orm_err)?;
    Ok(())
}

// ---------- viewing ----------

type HmacSha256 = Hmac<Sha256>;

fn mac_hex(st: &AppState, parts: &[&str]) -> String {
    let mut m = HmacSha256::new_from_slice(&st.secret[..]).expect("hmac key");
    for p in parts {
        m.update(p.as_bytes());
        m.update(b"\x1f");
    }
    m.finalize()
        .into_bytes()
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

/// Value of the per-video unlock cookie; changes when the password does.
pub fn unlock_token(st: &AppState, v: &Video) -> String {
    mac_hex(
        st,
        &["unlock", &v.id, v.password_hash.as_deref().unwrap_or("")],
    )
}

pub fn unlock_cookie_name(v: &Video) -> String {
    format!("sgu_{}", v.slug)
}

pub fn check_unlock(st: &AppState, v: &Video, cookie: Option<&str>) -> bool {
    use subtle::ConstantTimeEq;
    cookie.is_some_and(|c| bool::from(c.as_bytes().ct_eq(unlock_token(st, v).as_bytes())))
}

pub async fn verify_video_password(v: &Video, password: String) -> AppResult<bool> {
    match &v.password_hash {
        Some(h) => verify_password_blocking(password, h.clone()).await,
        None => Ok(false),
    }
}

/// Count a view once per viewer per UTC day; owners don't count. An idempotent insert
/// under the share context.
pub async fn record_view(
    st: &AppState,
    scope: &Scope,
    v: &Video,
    fingerprint: &str,
) -> AppResult<bool> {
    if scope.owns(v) || v.status != "ready" {
        return Ok(false);
    }
    let day = Utc::now().date_naive().to_string();
    let hash = mac_hex(st, &["view", &day, fingerprint]);
    let inserted = st
        .db
        .scoped(scope.share(v))
        .execute(
            "INSERT INTO item_views (id, item_id, workspace_id, viewer_hash, first_seen, owner_id) \
             VALUES ($1, $2, $3, $4, $5, $6) ON CONFLICT DO NOTHING",
            &vals![
                Uuid::new_v4(),
                v.id.as_str(),
                v.workspace_id.as_deref(),
                &hash[..32],
                now_ms(),
                v.user_id.as_str()
            ],
        )
        .await?;
    Ok(inserted > 0)
}

/// Upload progress reported by the app while it records. Ignored once the video is ready;
/// counts never move backwards, and once recording has ended it stays ended. A report
/// that changes nothing writes nothing (and so notifies nobody).
pub async fn progress(
    st: &AppState,
    scope: &Scope,
    v: &Video,
    uploaded_bytes: i64,
    recording: bool,
) -> AppResult<()> {
    if v.status == "ready" {
        return Ok(());
    }
    if !(0..=st.config.max_video_bytes).contains(&uploaded_bytes) {
        return Err(AppError::Invalid("uploaded_bytes is out of range".into()));
    }
    if uploaded_bytes < v.uploaded_bytes {
        return Err(AppError::Invalid("uploaded_bytes must not decrease".into()));
    }
    let ended = v.recording_ended_at.or_else(|| (!recording).then(now_ms));
    if uploaded_bytes == v.uploaded_bytes && ended == v.recording_ended_at {
        return Ok(());
    }
    let mut db = st.orm().await?;
    let mut tx = begin(&mut db, &scope.context()).await?;
    // Raw SQL: the guards make concurrent or replayed reports harmless. The end time is an
    // integer we produced (Toasty cannot bind an untyped NULL), so it is inlined.
    let ended = ended.map_or("NULL".to_string(), |t| t.to_string());
    toasty::sql::statement(format!(
        "UPDATE videos SET uploaded_bytes = GREATEST(uploaded_bytes, $2), \
         recording_ended_at = COALESCE(recording_ended_at, {ended}) \
         WHERE id = $1 AND status = 'pending'"
    ))
    .bind(v.id.as_str())
    .bind(uploaded_bytes)
    .exec(&mut tx)
    .await
    .map_err(orm_err)?;
    tx.commit().await.map_err(orm_err)?;
    Ok(())
}

/// Comments per item, for items visible under `ctx`.
pub async fn comment_counts(
    st: &AppState,
    ctx: Context,
    ids: &[&str],
) -> AppResult<HashMap<String, i64>> {
    counts(st, ctx, "item_comments", ids).await
}

/// Views per item, for items visible under `ctx`.
pub async fn view_counts(
    st: &AppState,
    ctx: Context,
    ids: &[&str],
) -> AppResult<HashMap<String, i64>> {
    counts(st, ctx, "item_views", ids).await
}

async fn counts(
    st: &AppState,
    ctx: Context,
    table: &'static str,
    ids: &[&str],
) -> AppResult<HashMap<String, i64>> {
    if ids.is_empty() {
        return Ok(HashMap::new());
    }
    let sql = format!(
        "SELECT item_id, COUNT(*) FROM {table} WHERE item_id IN ({}) GROUP BY item_id",
        crate::db::placeholders(1, ids.len())
    );
    let params: Vec<crate::db::Value> = ids.iter().map(|i| (*i).into()).collect();
    let rows = st.db.scoped(ctx).query(&sql, &params).await?;
    let mut out = HashMap::with_capacity(rows.len());
    for r in &rows {
        out.insert(r.text(0)?, r.i64(1)?);
    }
    Ok(out)
}

// ---------- conversation ----------

/// The latest [`MAX_LISTED`] comments, oldest first; the bound is in the query.
pub async fn comments(st: &AppState, scope: &Scope, v: &Video) -> AppResult<Vec<Comment>> {
    let mut db = st.orm().await?;
    let mut tx = begin(&mut db, &scope.share(v)).await?;
    let mut c = Comment::filter_by_item_id(&v.id)
        .order_by((
            Comment::fields().created_at().desc(),
            Comment::fields().id().desc(),
        ))
        .limit(MAX_LISTED)
        .exec(&mut tx)
        .await
        .map_err(orm_err)?;
    tx.commit().await.map_err(orm_err)?;
    c.reverse();
    Ok(c)
}

pub enum Author {
    Member { email: String },
    Guest { name: String },
}

pub async fn add_comment(
    st: &AppState,
    scope: &Scope,
    v: &Video,
    author: Author,
    body: &str,
    timestamp_ms: Option<i64>,
) -> AppResult<Comment> {
    let body = clean_text(body, MAX_COMMENT_CHARS)
        .ok_or_else(|| AppError::Invalid("write a comment first".into()))?;
    let name = match author {
        Author::Member { email } => email.split('@').next().unwrap_or("member").to_string(),
        Author::Guest { name } => {
            clean_line(&name, MAX_NAME_CHARS).unwrap_or_else(|| "Guest".into())
        }
    };
    let mut db = st.orm().await?;
    let mut tx = begin(&mut db, &scope.share(v)).await?;
    let c = toasty::create!(Comment {
        id: Uuid::new_v4().to_string(),
        item_id: v.id.clone(),
        workspace_id: v.workspace_id.clone(),
        owner_id: Some(v.user_id.clone()),
        user_id: scope.user_id.map(|u| u.to_string()),
        author_name: name,
        body,
        timestamp_ms: clamp_ts(v, timestamp_ms),
        created_at: now_ms(),
    })
    .exec(&mut tx)
    .await
    .map_err(orm_err)?;
    tx.commit().await.map_err(orm_err)?;
    Ok(c)
}

fn clamp_ts(v: &Video, t: Option<i64>) -> Option<i64> {
    t.filter(|t| *t >= 0).map(|t| {
        if v.duration_ms > 0 {
            t.min(v.duration_ms)
        } else {
            t.min(24 * 3_600_000)
        }
    })
}

pub async fn add_reaction(
    st: &AppState,
    scope: &Scope,
    v: &Video,
    emoji: &str,
    timestamp_ms: Option<i64>,
) -> AppResult<Reaction> {
    let emoji = EMOJIS
        .iter()
        .find(|e| **e == emoji)
        .ok_or_else(|| AppError::Invalid("unsupported reaction".into()))?;
    let mut db = st.orm().await?;
    let mut tx = begin(&mut db, &scope.share(v)).await?;
    let r = toasty::create!(Reaction {
        id: Uuid::new_v4().to_string(),
        item_id: v.id.clone(),
        workspace_id: v.workspace_id.clone(),
        owner_id: Some(v.user_id.clone()),
        user_id: scope.user_id.map(|u| u.to_string()),
        emoji: *emoji,
        timestamp_ms: clamp_ts(v, timestamp_ms),
        created_at: now_ms(),
    })
    .exec(&mut tx)
    .await
    .map_err(orm_err)?;
    tx.commit().await.map_err(orm_err)?;
    Ok(r)
}

/// Totals per emoji (allowlist order) and the latest timestamped reactions for markers.
pub async fn reactions(
    st: &AppState,
    scope: &Scope,
    v: &Video,
) -> AppResult<(Vec<(&'static str, i64)>, Vec<Reaction>)> {
    tokio::try_join!(
        reaction_totals(st, scope, v),
        reaction_markers(st, scope, v)
    )
}

/// Reactions per emoji, in allowlist order (one grouped count).
pub async fn reaction_totals(
    st: &AppState,
    scope: &Scope,
    v: &Video,
) -> AppResult<Vec<(&'static str, i64)>> {
    let rows = st
        .db
        .scoped(scope.share(v))
        .query(
            "SELECT emoji, COUNT(*) FROM item_reactions WHERE item_id = $1 GROUP BY emoji",
            &vals![v.id.as_str()],
        )
        .await?;
    let mut totals: Vec<(&'static str, i64)> = EMOJIS.iter().map(|e| (*e, 0)).collect();
    for r in rows {
        let (e, n) = (r.text(0)?, r.i64(1)?);
        if let Some(t) = totals.iter_mut().find(|t| t.0 == e) {
            t.1 = n;
        }
    }
    Ok(totals)
}

/// The latest [`MAX_LISTED`] timestamped reactions, oldest first, for timeline markers.
pub async fn reaction_markers(st: &AppState, scope: &Scope, v: &Video) -> AppResult<Vec<Reaction>> {
    let mut db = st.orm().await?;
    let mut tx = begin(&mut db, &scope.share(v)).await?;
    let mut recent = Reaction::filter_by_item_id(&v.id)
        .filter(Reaction::fields().timestamp_ms().is_some())
        .order_by((
            Reaction::fields().created_at().desc(),
            Reaction::fields().id().desc(),
        ))
        .limit(MAX_LISTED)
        .exec(&mut tx)
        .await
        .map_err(orm_err)?;
    tx.commit().await.map_err(orm_err)?;
    recent.reverse();
    Ok(recent)
}

/// WebVTT text for the watch page (fetched from storage, small).
pub async fn transcript(st: &AppState, v: &Video) -> AppResult<Option<String>> {
    let Some(key) = &v.transcript_key else {
        return Ok(None);
    };
    let bytes = st
        .store
        .get_bytes(key, MAX_TRANSCRIPT_BYTES as usize)
        .await
        .map_err(store_err)?;
    Ok(bytes.map(|b| String::from_utf8_lossy(&b).into_owned()))
}

// ---------- retention (RLS maintenance bypass) ----------

/// One batch of expired or abandoned videos; returns `(expired, aborted)`.
pub async fn purge_batch(st: &AppState, now: i64, limit: usize) -> AppResult<(usize, usize)> {
    let ctx = Context::maintenance();
    let rows = st
        .db
        .scoped(ctx.clone())
        .query(
            "SELECT id FROM videos WHERE expires_at <= $1 OR (status = 'pending' AND created_at < $2) \
             ORDER BY created_at LIMIT $3",
            &vals![now, now - STALE_PENDING_MS, limit as i64],
        )
        .await?;
    let (mut expired, mut aborted) = (0, 0);
    for r in rows {
        let id = r.text(0)?;
        let mut db = st.orm().await?;
        let mut tx = begin(&mut db, &ctx).await?;
        let v = Video::filter_by_id(&id)
            .first()
            .exec(&mut tx)
            .await
            .map_err(orm_err)?;
        tx.commit().await.map_err(orm_err)?;
        let Some(v) = v else { continue };
        purge(st, &ctx, &v).await?;
        if v.expires_at <= now {
            expired += 1;
        } else {
            aborted += 1;
        }
    }
    Ok((expired, aborted))
}

/// Remove every video of a user (account purge).
pub async fn purge_user(st: &AppState, user_id: Uuid) -> AppResult<()> {
    let ctx = Context::maintenance();
    let mut db = st.orm().await?;
    let mut tx = begin(&mut db, &ctx).await?;
    let videos = Video::filter_by_user_id(user_id.to_string())
        .exec(&mut tx)
        .await
        .map_err(orm_err)?;
    tx.commit().await.map_err(orm_err)?;
    for v in &videos {
        purge(st, &ctx, v).await?;
    }
    Ok(())
}
