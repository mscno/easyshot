use std::time::Duration;

use axum::extract::{Path, Query, State};
use axum::http::StatusCode;
use axum::Json;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use chrono::{DateTime, Datelike, TimeZone, Utc};
use serde::Deserialize;
use serde_json::{json, Value};
use uuid::Uuid;

use super::ApiJson;
use crate::auth::{generate_slug, AuthUser};
use crate::error::{AppError, AppResult};
use crate::repo::{self, now_ms, ts, NewScreenshot, Screenshot};
use crate::state::AppState;

pub const UPLOAD_TTL: Duration = Duration::from_secs(600);
pub const IMAGE_URL_TTL: Duration = Duration::from_secs(3600);

pub fn ext_for(content_type: &str) -> Option<&'static str> {
    match content_type {
        "image/png" => Some("png"),
        "image/jpeg" => Some("jpg"),
        "image/gif" => Some("gif"),
        "image/webp" => Some("webp"),
        _ => None,
    }
}

pub fn object_key(user_id: Uuid, id: Uuid, now: DateTime<Utc>, ext: &str) -> String {
    format!(
        "u/{user_id}/{:04}/{:02}/{id}.{ext}",
        now.year(),
        now.month()
    )
}

pub fn encode_cursor(created_at: DateTime<Utc>, id: Uuid) -> String {
    URL_SAFE_NO_PAD.encode(format!("{}.{}", created_at.timestamp_micros(), id))
}

pub fn decode_cursor(c: &str) -> Option<(DateTime<Utc>, Uuid)> {
    let raw = String::from_utf8(URL_SAFE_NO_PAD.decode(c).ok()?).ok()?;
    let (micros, id) = raw.split_once('.')?;
    let ts = Utc.timestamp_micros(micros.parse().ok()?).single()?;
    Some((ts, Uuid::parse_str(id).ok()?))
}

fn parse_id(s: &str) -> AppResult<Uuid> {
    Uuid::parse_str(s).map_err(|_| AppError::NotFound)
}

#[derive(Deserialize)]
pub struct CreateBody {
    content_type: String,
    byte_size: i64,
    width: Option<i32>,
    height: Option<i32>,
    filename: Option<String>,
}

pub async fn create(
    State(st): State<AppState>,
    user: AuthUser,
    ApiJson(b): ApiJson<CreateBody>,
) -> AppResult<(StatusCode, Json<Value>)> {
    if st.config.require_email_verification && !user.email_verified {
        return Err(AppError::EmailNotVerified);
    }
    let content_type = b.content_type.trim().to_ascii_lowercase();
    let ext = ext_for(&content_type).ok_or(AppError::UnsupportedType)?;
    if b.byte_size <= 0 {
        return Err(AppError::Invalid("byte_size must be positive".into()));
    }
    if b.byte_size > st.config.max_upload_bytes {
        return Err(AppError::TooLarge);
    }
    if b.width.is_some_and(|w| w <= 0) || b.height.is_some_and(|h| h <= 0) {
        return Err(AppError::Invalid("width/height must be positive".into()));
    }
    let filename = b
        .filename
        .map(|f| f.trim().chars().take(255).collect::<String>())
        .filter(|f| !f.is_empty());

    let now_ms = now_ms();
    let now = ts(now_ms);
    let expires_ms = now_ms + st.config.retention_days * 86_400_000;
    let expires_at = ts(expires_ms);
    let id = Uuid::new_v4();
    let key = object_key(user.id, id, now, ext);

    let mut slug = None;
    for _ in 0..8 {
        let candidate = generate_slug();
        let inserted = repo::insert_screenshot(
            &st.db,
            &NewScreenshot {
                id,
                user_id: user.id,
                slug: &candidate,
                object_key: &key,
                content_type: &content_type,
                byte_size: b.byte_size,
                width: b.width,
                height: b.height,
                filename: filename.as_deref(),
                now: now_ms,
                expires_at: expires_ms,
            },
        )
        .await?;
        if inserted {
            slug = Some(candidate);
            break;
        }
    }
    let slug = slug.ok_or_else(|| AppError::Internal("could not allocate slug".into()))?;

    let put = st
        .store
        .presign_put(&key, &content_type, b.byte_size, UPLOAD_TTL)
        .await
        .map_err(|e| AppError::Storage(e.0))?;
    let headers: serde_json::Map<String, Value> = put
        .headers
        .into_iter()
        .map(|(k, v)| (k, Value::String(v)))
        .collect();
    Ok((
        StatusCode::CREATED,
        Json(json!({
            "id": id.to_string(),
            "slug": slug,
            "share_url": share_url(&st, &slug, ext),
            "expires_at": expires_at,
            "upload": {"method": "PUT", "url": put.url, "headers": headers},
        })),
    ))
}

fn share_url(st: &AppState, slug: &str, ext: &str) -> String {
    format!("{}/s/{slug}.{ext}", st.config.public_base_url)
}

async fn to_json(st: &AppState, r: &Screenshot) -> AppResult<Value> {
    let ext = ext_for(&r.content_type).unwrap_or("png");
    let image_url = st
        .store
        .presign_get(&r.object_key, IMAGE_URL_TTL, &r.content_type)
        .await
        .map_err(|e| AppError::Storage(e.0))?;
    Ok(json!({
        "id": r.id.to_string(),
        "slug": r.slug,
        "share_url": share_url(st, &r.slug, ext),
        "content_type": r.content_type,
        "byte_size": r.byte_size,
        "width": r.width,
        "height": r.height,
        "filename": r.filename,
        "created_at": ts(r.created_at),
        "expires_at": ts(r.expires_at),
        "image_url": image_url,
    }))
}

pub async fn complete(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<String>,
) -> AppResult<Json<Value>> {
    let id = parse_id(&id)?;
    let row = repo::get_screenshot(&st.db, id, user.id)
        .await?
        .ok_or(AppError::NotFound)?;
    if row.status == "ready" {
        return Ok(Json(to_json(&st, &row).await?));
    }
    let meta = st
        .store
        .head(&row.object_key)
        .await
        .map_err(|e| AppError::Storage(e.0))?
        .ok_or(AppError::NotUploaded)?;
    if meta.size != row.byte_size {
        st.store
            .delete_many(std::slice::from_ref(&row.object_key))
            .await
            .map_err(|e| AppError::Storage(e.0))?;
        repo::delete_screenshot(&st.db, id, user.id).await?;
        return Err(AppError::SizeMismatch);
    }
    repo::mark_ready(&st.db, id, now_ms()).await?;
    Ok(Json(to_json(&st, &row).await?))
}

#[derive(Deserialize)]
pub struct ListQuery {
    limit: Option<i64>,
    before: Option<String>,
}

pub async fn list(
    State(st): State<AppState>,
    user: AuthUser,
    Query(q): Query<ListQuery>,
) -> AppResult<Json<Value>> {
    let limit = q.limit.unwrap_or(50).clamp(1, 100);
    let cursor = match q.before.as_deref().filter(|s| !s.is_empty()) {
        Some(c) => {
            Some(decode_cursor(c).ok_or_else(|| AppError::Invalid("invalid cursor".into()))?)
        }
        None => None,
    };
    let before = cursor.map(|(t, i)| (t.timestamp_millis(), i));
    let mut rows = repo::list_ready(&st.db, user.id, now_ms(), before, limit + 1).await?;
    let next_cursor = if rows.len() as i64 > limit {
        rows.truncate(limit as usize);
        rows.last().map(|r| encode_cursor(ts(r.created_at), r.id))
    } else {
        None
    };
    let mut items = Vec::with_capacity(rows.len());
    for r in &rows {
        items.push(to_json(&st, r).await?);
    }
    Ok(Json(json!({"items": items, "next_cursor": next_cursor})))
}

pub async fn delete(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<String>,
) -> AppResult<StatusCode> {
    let id = parse_id(&id)?;
    let key = repo::get_screenshot(&st.db, id, user.id)
        .await?
        .ok_or(AppError::NotFound)?
        .object_key;
    st.store
        .delete_many(std::slice::from_ref(&key))
        .await
        .map_err(|e| AppError::Storage(e.0))?;
    repo::delete_screenshot(&st.db, id, user.id).await?;
    Ok(StatusCode::NO_CONTENT)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn content_types() {
        assert_eq!(ext_for("image/png"), Some("png"));
        assert_eq!(ext_for("image/jpeg"), Some("jpg"));
        assert_eq!(ext_for("image/gif"), Some("gif"));
        assert_eq!(ext_for("image/webp"), Some("webp"));
        assert_eq!(ext_for("video/mp4"), None);
        assert_eq!(ext_for("image/svg+xml"), None);
    }

    #[test]
    fn cursor_roundtrip() {
        let t = Utc.timestamp_micros(1_700_000_123_456_789).unwrap();
        let id = Uuid::new_v4();
        let c = encode_cursor(t, id);
        assert_eq!(decode_cursor(&c), Some((t, id)));
        assert_eq!(decode_cursor("garbage!"), None);
        assert_eq!(decode_cursor(&URL_SAFE_NO_PAD.encode("x.y")), None);
    }

    #[test]
    fn key_layout() {
        let t = Utc.with_ymd_and_hms(2026, 3, 9, 0, 0, 0).unwrap();
        let (u, i) = (Uuid::nil(), Uuid::nil());
        assert_eq!(object_key(u, i, t, "png"), format!("u/{u}/2026/03/{i}.png"));
    }
}
