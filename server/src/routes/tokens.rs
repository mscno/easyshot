use axum::Json;
use axum::extract::{Path, State};
use axum::http::StatusCode;
use serde::Deserialize;
use serde_json::{Value, json};
use uuid::Uuid;

use super::ApiJson;
use crate::auth::{API_PREFIX, AuthUser, generate_token};
use crate::error::{AppError, AppResult};
use crate::repo::{self, now_ms, ts};
use crate::state::AppState;

#[derive(Deserialize)]
pub struct CreateToken {
    name: String,
}

pub async fn create(
    State(st): State<AppState>,
    user: AuthUser,
    ApiJson(body): ApiJson<CreateToken>,
) -> AppResult<(StatusCode, Json<Value>)> {
    // An unverified account may be someone else's reservation of the address: it holds no
    // lasting credentials until its mailbox is proven.
    if st.mailer.enabled() && !user.email_verified {
        return Err(AppError::EmailNotVerified);
    }
    let name = body.name.trim().to_string();
    if name.is_empty() || name.chars().count() > 100 {
        return Err(AppError::Invalid("name must be 1-100 characters".into()));
    }
    let (token, hash) = generate_token(API_PREFIX);
    let id = Uuid::new_v4();
    let now = now_ms();
    repo::insert_api_token(&st.db, id, user.id, &name, &hash, now).await?;
    let created_at = ts(now);
    Ok((
        StatusCode::CREATED,
        Json(json!({"id": id.to_string(), "name": name, "token": token, "created_at": created_at})),
    ))
}

pub async fn list(State(st): State<AppState>, user: AuthUser) -> AppResult<Json<Value>> {
    let rows = repo::list_api_tokens(&st.db, user.id).await?;
    let items: Vec<Value> = rows
        .into_iter()
        .map(|r| json!({"id": r.id.to_string(), "name": r.name, "created_at": ts(r.created_at), "last_used_at": r.last_used_at.map(ts)}))
        .collect();
    Ok(Json(json!({"items": items})))
}

pub async fn revoke(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<String>,
) -> AppResult<StatusCode> {
    let id = Uuid::parse_str(&id).map_err(|_| AppError::NotFound)?;
    if !repo::revoke_api_token(&st.db, id, user.id, now_ms()).await? {
        return Err(AppError::NotFound);
    }
    Ok(StatusCode::NO_CONTENT)
}
