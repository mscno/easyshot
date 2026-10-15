use axum::extract::State;
use axum::http::{HeaderMap, StatusCode};
use axum::Json;
use chrono::{DateTime, Utc};
use serde::Deserialize;
use serde_json::{json, Value};
use uuid::Uuid;

use super::ApiJson;
use crate::auth::{
    dummy_hash, generate_token, hash_password_blocking, verify_password_blocking, AuthUser,
    SESSION_PREFIX, SESSION_TTL_MS,
};
use crate::db::DbError;
use crate::error::{AppError, AppResult};
use crate::mailer::CodePurpose;
use crate::repo::{self, now_ms, ts};
use crate::state::AppState;

#[derive(Deserialize)]
pub struct Credentials {
    email: String,
    password: String,
    device_name: Option<String>,
}

pub fn normalize_email(raw: &str) -> Result<String, AppError> {
    let e = raw.trim().to_lowercase();
    let ok = e.len() <= 254
        && !e.contains(char::is_whitespace)
        && e.split_once('@')
            .map(|(l, d)| {
                !l.is_empty()
                    && d.contains('.')
                    && !d.starts_with('.')
                    && !d.ends_with('.')
                    && !d.contains('@')
            })
            .unwrap_or(false);
    if ok {
        Ok(e)
    } else {
        Err(AppError::Invalid("invalid email address".into()))
    }
}

pub fn clean_device(d: Option<String>) -> Option<String> {
    d.map(|s| s.trim().chars().take(100).collect::<String>())
        .filter(|s| !s.is_empty())
}

pub fn user_json(
    id: Uuid,
    email: &str,
    plan: &str,
    created_at: DateTime<Utc>,
    email_verified: bool,
) -> Value {
    json!({"id": id.to_string(), "email": email, "plan": plan, "created_at": created_at, "email_verified": email_verified})
}

pub async fn issue_session(
    st: &AppState,
    user: Value,
    user_id: Uuid,
    device: Option<String>,
) -> AppResult<Json<Value>> {
    let (token, hash) = generate_token(SESSION_PREFIX);
    let now = now_ms();
    let expires_at = now + SESSION_TTL_MS;
    repo::insert_session(&st.db, user_id, &hash, device.as_deref(), now, expires_at).await?;
    Ok(Json(
        json!({"token": token, "expires_at": ts(expires_at), "user": user}),
    ))
}

pub async fn register(
    State(st): State<AppState>,
    ApiJson(body): ApiJson<Credentials>,
) -> AppResult<(StatusCode, Json<Value>)> {
    if !st.config.allow_signups {
        return Err(AppError::SignupsDisabled);
    }
    let email = normalize_email(&body.email)?;
    let pw_len = body.password.chars().count();
    if !(10..=256).contains(&pw_len) {
        return Err(AppError::Invalid(
            "password must be between 10 and 256 characters".into(),
        ));
    }
    let hash = hash_password_blocking(body.password).await?;

    let id = Uuid::new_v4();
    let now = now_ms();
    match repo::create_user(&st.db, id, &email, &hash, now).await {
        Ok(()) => {}
        Err(DbError::UniqueViolation) => return Err(AppError::EmailTaken),
        Err(e) => return Err(e.into()),
    }
    let user = user_json(id, &email, "free", ts(now), false);
    if st.mailer.enabled() {
        super::codes::send_code(&st, id, &email, CodePurpose::VerifyEmail);
    }
    let json = issue_session(&st, user, id, clean_device(body.device_name)).await?;
    Ok((StatusCode::CREATED, json))
}

fn client_ip(headers: &HeaderMap) -> Option<String> {
    headers
        .get("x-forwarded-for")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.split(',').next())
        .map(|s| s.trim().chars().take(64).collect())
        .filter(|s: &String| !s.is_empty())
}

pub async fn login(
    State(st): State<AppState>,
    headers: HeaderMap,
    ApiJson(body): ApiJson<Credentials>,
) -> AppResult<Json<Value>> {
    // Anything that can't be a valid email still counts as a failed credential, not a 400.
    let email = body.email.trim().to_lowercase();
    let ip = client_ip(&headers);

    let now = now_ms();
    let failed = repo::count_failed_logins(&st.db, &email, now - 15 * 60_000).await?;
    if failed >= 10 {
        return Err(AppError::RateLimited);
    }

    let row = repo::find_user_for_login(&st.db, &email).await?;
    let (hash, row) = match row {
        Some(r) => (r.password_hash.clone(), Some(r)),
        None => (dummy_hash().to_string(), None),
    };
    let ok = verify_password_blocking(body.password, hash).await?;
    let valid = match row {
        Some(r) if ok && !r.disabled => Some(r),
        _ => None,
    };

    repo::record_login_attempt(&st.db, &email, ip, valid.is_some(), now).await?;

    let r = valid.ok_or(AppError::InvalidCredentials)?;
    repo::touch_user(&st.db, r.id, now).await?;
    let user = user_json(r.id, &email, &r.plan, ts(r.created_at), r.email_verified);
    issue_session(&st, user, r.id, clean_device(body.device_name)).await
}

pub async fn logout(State(st): State<AppState>, user: AuthUser) -> AppResult<StatusCode> {
    if let Some(sid) = user.session_id {
        repo::delete_session(&st.db, sid).await?;
    }
    Ok(StatusCode::NO_CONTENT)
}

pub async fn me(State(st): State<AppState>, user: AuthUser) -> AppResult<Json<Value>> {
    let (n, bytes) = repo::usage(&st.db, user.id, now_ms()).await?;
    Ok(Json(json!({
        "id": user.id.to_string(),
        "email": user.email,
        "plan": user.plan,
        "email_verified": user.email_verified,
        "created_at": user.created_at,
        "retention_days": st.config.retention_days,
        "usage": {"screenshots": n, "bytes": bytes},
    })))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn emails() {
        assert_eq!(
            normalize_email("  Foo@Example.COM ").unwrap(),
            "foo@example.com"
        );
        assert!(normalize_email("nope").is_err());
        assert!(normalize_email("a@b").is_err());
        assert!(normalize_email("a b@c.d").is_err());
        assert!(normalize_email("@c.d").is_err());
    }
}
