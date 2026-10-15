//! JSON API for the Mac app: Loom-style recordings. The share link exists as soon as the
//! video is created; the client streams parts to presigned URLs while still recording and
//! completes the upload when it stops. Video bytes never pass through this server.

use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::Json;
use serde::Deserialize;
use serde_json::{json, Map, Value};

use super::ApiJson;
use crate::auth::AuthUser;
use crate::error::{AppError, AppResult};
use crate::repo::ts;
use crate::state::AppState;
use crate::storage::PresignedPut;
use crate::video::model::Video;
use crate::video::scope::{Scope, Visibility};
use crate::video::service::{
    self, share_url, Asset, Completion, Edit, NewVideo, MAX_PART_BATCH, MIN_PART_BYTES,
    PART_URL_TTL,
};

fn scope(st: &AppState, user: &AuthUser) -> AppResult<Scope> {
    if st.config.require_email_verification && !user.email_verified {
        return Err(AppError::EmailNotVerified);
    }
    Ok(Scope::user(user.id))
}

pub fn video_json(st: &AppState, v: &Video) -> Value {
    json!({
        "id": v.id,
        "kind": v.kind,
        "slug": v.slug,
        "share_url": share_url(st, &v.slug),
        "title": v.title,
        "status": v.status,
        "visibility": v.visibility,
        "content_type": v.content_type,
        "byte_size": v.byte_size,
        "duration_ms": v.duration_ms,
        "width": v.width,
        "height": v.height,
        "has_thumbnail": v.thumbnail_key.is_some(),
        "has_transcript": v.transcript_key.is_some(),
        "created_at": ts(v.created_at),
        "expires_at": ts(v.expires_at),
    })
}

fn put_json(put: PresignedPut) -> Value {
    let headers: Map<String, Value> = put
        .headers
        .into_iter()
        .map(|(k, v)| (k, Value::String(v)))
        .collect();
    json!({"method": "PUT", "url": put.url, "headers": headers})
}

#[derive(Deserialize)]
pub struct CreateBody {
    title: Option<String>,
    content_type: Option<String>,
}

pub async fn create(
    State(st): State<AppState>,
    user: AuthUser,
    ApiJson(b): ApiJson<CreateBody>,
) -> AppResult<(StatusCode, Json<Value>)> {
    let scope = scope(&st, &user)?;
    let v = service::create(
        &st,
        &scope,
        NewVideo {
            title: b.title,
            content_type: b.content_type.unwrap_or_else(|| "video/mp4".into()),
        },
    )
    .await?;
    let mut body = video_json(&st, &v);
    body["upload"] = json!({
        "min_part_bytes": MIN_PART_BYTES,
        "max_bytes": st.config.max_video_bytes,
        "max_part_batch": MAX_PART_BATCH,
        "part_url_ttl_seconds": PART_URL_TTL.as_secs(),
    });
    Ok((StatusCode::CREATED, Json(body)))
}

pub async fn list(State(st): State<AppState>, user: AuthUser) -> AppResult<Json<Value>> {
    let items = Scope::user(user.id).items(&st, 200).await?;
    Ok(Json(
        json!({"items": items.iter().map(|v| video_json(&st, v)).collect::<Vec<_>>()}),
    ))
}

pub async fn get(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<String>,
) -> AppResult<Json<Value>> {
    let v = Scope::user(user.id).managed(&st, &id).await?;
    Ok(Json(video_json(&st, &v)))
}

#[derive(Deserialize)]
pub struct PartsBody {
    part_numbers: Vec<i32>,
}

pub async fn parts(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<String>,
    ApiJson(b): ApiJson<PartsBody>,
) -> AppResult<Json<Value>> {
    let v = scope(&st, &user)?.managed(&st, &id).await?;
    let urls = service::presign_parts(&st, &v, &b.part_numbers).await?;
    Ok(Json(json!({
        "parts": urls.into_iter().map(|(n, url)| json!({"part_number": n, "method": "PUT", "url": url})).collect::<Vec<_>>(),
        "expires_in": PART_URL_TTL.as_secs(),
    })))
}

#[derive(Deserialize)]
pub struct CompletedPartBody {
    part_number: i32,
    etag: String,
}

#[derive(Deserialize)]
pub struct CompleteBody {
    parts: Vec<CompletedPartBody>,
    duration_ms: Option<i64>,
    width: Option<i64>,
    height: Option<i64>,
}

pub async fn complete(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<String>,
    ApiJson(b): ApiJson<CompleteBody>,
) -> AppResult<Json<Value>> {
    let scope = scope(&st, &user)?;
    let v = scope.managed(&st, &id).await?;
    let v = service::complete(
        &st,
        &scope,
        v,
        Completion {
            parts: b.parts.into_iter().map(|p| (p.part_number, p.etag)).collect(),
            duration_ms: b.duration_ms,
            width: b.width,
            height: b.height,
        },
    )
    .await?;
    Ok(Json(video_json(&st, &v)))
}

#[derive(Deserialize)]
pub struct AssetBody {
    byte_size: i64,
}

async fn asset(st: AppState, user: AuthUser, id: String, b: AssetBody, kind: Asset) -> AppResult<Json<Value>> {
    let scope = scope(&st, &user)?;
    let v = scope.managed(&st, &id).await?;
    let put = service::presign_asset(&st, &scope, &v, kind, b.byte_size).await?;
    Ok(Json(json!({"upload": put_json(put)})))
}

pub async fn thumbnail(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<String>,
    ApiJson(b): ApiJson<AssetBody>,
) -> AppResult<Json<Value>> {
    asset(st, user, id, b, Asset::Thumbnail).await
}

pub async fn transcript(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<String>,
    ApiJson(b): ApiJson<AssetBody>,
) -> AppResult<Json<Value>> {
    asset(st, user, id, b, Asset::Transcript).await
}

#[derive(Deserialize)]
pub struct PatchBody {
    title: Option<String>,
    visibility: Option<String>,
    password: Option<String>,
}

pub async fn update(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<String>,
    ApiJson(b): ApiJson<PatchBody>,
) -> AppResult<Json<Value>> {
    let scope = Scope::user(user.id);
    let v = scope.managed(&st, &id).await?;
    let visibility = match b.visibility.as_deref() {
        None => None,
        Some(s) => Some(
            Visibility::parse(s)
                .ok_or_else(|| AppError::Invalid("visibility must be link, password or private".into()))?,
        ),
    };
    let v = service::edit(
        &st,
        &scope,
        &v,
        Edit {
            title: b.title,
            visibility,
            password: b.password,
        },
    )
    .await?;
    Ok(Json(video_json(&st, &v)))
}

pub async fn delete(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<String>,
) -> AppResult<StatusCode> {
    let scope = Scope::user(user.id);
    let v = scope.managed(&st, &id).await?;
    service::purge(&st, &scope.context(), &v).await?;
    Ok(StatusCode::NO_CONTENT)
}
