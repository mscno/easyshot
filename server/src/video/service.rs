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

use super::live::Change;
use super::model::{Comment, ItemView, Reaction, Video};
use super::scope::{Scope, Visibility};
use crate::auth::{generate_slug, hash_password_blocking, verify_password_blocking};
use crate::db::Context;
use crate::error::{AppError, AppResult};
use crate::orm::{begin, is_unique_violation, orm_err};
use crate::repo::{now_ms, ts};
use crate::state::AppState;
use crate::vals;

/// S3 requires every part except the last to be at least 5 MiB.
pub const MIN_PART_BYTES: i64 = 5 * 1024 * 1024;
pub const MAX_PARTS: i32 = 10_000;
/// Part URLs requested in one call.
pub const MAX_PART_BATCH: usize = 100;
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
    let upload_id = st
        .store
        .create_multipart(&key, &content_type)
        .await
        .map_err(store_err)?;
    let expires_at = now + st.config.video_retention_days * 86_400_000;
    let mut db = st.orm().await?;
    for _ in 0..8 {
        let mut tx = begin(&mut db, &scope.context()).await?;
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
        })
        .exec(&mut tx)
        .await;
        match created {
            Ok(v) => {
                tx.commit().await.map_err(orm_err)?;
                return Ok(v);
            }
            Err(e) if is_unique_violation(&e) => continue,
            Err(e) => {
                drop(tx);
                let _ = st.store.abort_multipart(&key, &upload_id).await;
                return Err(orm_err(e));
            }
        }
    }
    let _ = st.store.abort_multipart(&key, &upload_id).await;
    Err(AppError::Internal("could not allocate slug".into()))
}

pub async fn presign_parts(
    st: &AppState,
    v: &Video,
    part_numbers: &[i32],
) -> AppResult<Vec<(i32, String)>> {
    let upload_id = match (&v.upload_id, v.status.as_str()) {
        (Some(u), "pending") => u,
        _ => return Err(AppError::Invalid("upload already completed".into())),
    };
    if part_numbers.is_empty() || part_numbers.len() > MAX_PART_BATCH {
        return Err(AppError::Invalid(format!(
            "request between 1 and {MAX_PART_BATCH} part numbers"
        )));
    }
    let mut out = Vec::with_capacity(part_numbers.len());
    for &n in part_numbers {
        if !(1..=MAX_PARTS).contains(&n) {
            return Err(AppError::Invalid(format!(
                "part numbers must be between 1 and {MAX_PARTS}"
            )));
        }
        let url = st
            .store
            .presign_upload_part(&v.object_key, upload_id, n, PART_URL_TTL)
            .await
            .map_err(store_err)?;
        out.push((n, url));
    }
    Ok(out)
}

pub struct Completion {
    pub parts: Vec<(i32, String)>,
    pub duration_ms: Option<i64>,
    pub width: Option<i64>,
    pub height: Option<i64>,
}

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
        return Err(AppError::Invalid("parts must not be empty".into()));
    }
    parts.sort_by_key(|p| p.0);
    if parts.windows(2).any(|w| w[0].0 == w[1].0)
        || parts
            .iter()
            .any(|(n, tag)| !(1..=MAX_PARTS).contains(n) || tag.is_empty() || tag.len() > 200)
    {
        return Err(AppError::Invalid("invalid parts list".into()));
    }
    if c.width.is_some_and(|w| w <= 0) || c.height.is_some_and(|h| h <= 0) {
        return Err(AppError::Invalid("width/height must be positive".into()));
    }
    st.store
        .complete_multipart(&v.object_key, &upload_id, &parts)
        .await
        .map_err(|e| {
            if e.0.contains("InvalidPart") || e.0.contains("EntityTooSmall") {
                AppError::Invalid(format!("upload could not be completed: {}", e.0))
            } else {
                store_err(e)
            }
        })?;
    let meta = st
        .store
        .head(&v.object_key)
        .await
        .map_err(store_err)?
        .ok_or(AppError::NotUploaded)?;
    if meta.size > st.config.max_video_bytes {
        purge(st, &scope.context(), &v).await?;
        return Err(AppError::TooLarge);
    }
    let now = now_ms();
    let duration = c.duration_ms.unwrap_or(0).clamp(0, 24 * 3_600_000);
    let mut db = st.orm().await?;
    let mut tx = begin(&mut db, &scope.context()).await?;
    Video::update_by_id(&v.id)
        .status("ready")
        .upload_id(None::<String>)
        .byte_size(meta.size)
        .duration_ms(duration)
        .width(c.width.or(v.width))
        .height(c.height.or(v.height))
        .ready_at(Some(now))
        .updated_at(now)
        .exec(&mut tx)
        .await
        .map_err(orm_err)?;
    tx.commit().await.map_err(orm_err)?;
    st.live.publish(&v.id, Change::Video);
    scope.managed(st, &v.id).await
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
}

/// Presigned PUT for a poster frame or WebVTT transcript; records its key on the video.
pub async fn presign_asset(
    st: &AppState,
    scope: &Scope,
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
    let key = format!(
        "{}.{}",
        base_key(&v.user_id, &v.id, v.created_at),
        asset.ext()
    );
    let put = st
        .store
        .presign_put(&key, asset.content_type(), byte_size, ASSET_PUT_TTL)
        .await
        .map_err(store_err)?;
    let mut db = st.orm().await?;
    let mut tx = begin(&mut db, &scope.context()).await?;
    let q = Video::update_by_id(&v.id).updated_at(now_ms());
    let q = match asset {
        Asset::Thumbnail => q.thumbnail_key(Some(key)),
        Asset::Transcript => q.transcript_key(Some(key)),
    };
    q.exec(&mut tx).await.map_err(orm_err)?;
    tx.commit().await.map_err(orm_err)?;
    if asset == Asset::Transcript {
        st.live.publish(&v.id, Change::Video);
    }
    Ok(put)
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
    st.live.publish(&v.id, Change::Video);
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
    Video::filter_by_id(&v.id)
        .delete()
        .exec(&mut tx)
        .await
        .map_err(orm_err)?;
    tx.commit().await.map_err(orm_err)?;
    st.live.publish(&v.id, Change::Gone);
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
            "INSERT INTO item_views (id, item_id, workspace_id, viewer_hash, first_seen) \
             VALUES ($1, $2, $3, $4, $5) ON CONFLICT DO NOTHING",
            &vals![
                Uuid::new_v4(),
                v.id.as_str(),
                v.workspace_id.as_deref(),
                &hash[..32],
                now_ms()
            ],
        )
        .await?;
    Ok(inserted > 0)
}

/// Views per item, for items visible under `ctx`.
pub async fn view_counts(
    st: &AppState,
    ctx: Context,
    ids: &[&str],
) -> AppResult<HashMap<String, i64>> {
    if ids.is_empty() {
        return Ok(HashMap::new());
    }
    let sql = format!(
        "SELECT item_id, COUNT(*) FROM item_views WHERE item_id IN ({}) GROUP BY item_id",
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

pub async fn comments(st: &AppState, scope: &Scope, v: &Video) -> AppResult<Vec<Comment>> {
    let mut db = st.orm().await?;
    let mut tx = begin(&mut db, &scope.share(v)).await?;
    let mut c = Comment::filter_by_item_id(&v.id)
        .exec(&mut tx)
        .await
        .map_err(orm_err)?;
    tx.commit().await.map_err(orm_err)?;
    c.sort_by(|a, b| a.created_at.cmp(&b.created_at).then(a.id.cmp(&b.id)));
    let skip = c.len().saturating_sub(MAX_LISTED);
    Ok(c.split_off(skip))
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
    st.live.publish(&v.id, Change::Comments);
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
        user_id: scope.user_id.map(|u| u.to_string()),
        emoji: *emoji,
        timestamp_ms: clamp_ts(v, timestamp_ms),
        created_at: now_ms(),
    })
    .exec(&mut tx)
    .await
    .map_err(orm_err)?;
    tx.commit().await.map_err(orm_err)?;
    st.live.publish(&v.id, Change::Reactions);
    Ok(r)
}

/// Totals per emoji (allowlist order) and the latest timestamped reactions for markers.
pub async fn reactions(
    st: &AppState,
    scope: &Scope,
    v: &Video,
) -> AppResult<(Vec<(&'static str, i64)>, Vec<Reaction>)> {
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
    let mut db = st.orm().await?;
    let mut tx = begin(&mut db, &scope.share(v)).await?;
    let mut recent = Reaction::filter_by_item_id(&v.id)
        .exec(&mut tx)
        .await
        .map_err(orm_err)?;
    tx.commit().await.map_err(orm_err)?;
    recent.retain(|r| r.timestamp_ms.is_some());
    recent.sort_by(|a, b| a.created_at.cmp(&b.created_at));
    let skip = recent.len().saturating_sub(MAX_LISTED);
    Ok((totals, recent.split_off(skip)))
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
