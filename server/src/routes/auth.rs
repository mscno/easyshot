use axum::Json;
use axum::extract::State;
use axum::http::StatusCode;
use chrono::{DateTime, Utc};
use serde::Deserialize;
use serde_json::{Value, json};
use uuid::Uuid;

use super::ApiJson;
use super::codes::{send_attempt_code, sign_up_attempt};
use crate::auth::{
    AuthUser, Bucket, ClientAddr, SESSION_PREFIX, SESSION_TTL_MS, check_password, generate_token,
    hash_password_blocking, throttle,
};
use crate::db::DbError;
use crate::error::{AppError, AppResult};
use crate::repo::{self, LoginUser, now_ms, ts};
use crate::state::AppState;

/// Failed password sign-ins per email within [`LOGIN_WINDOW_MS`] before password sign-in
/// is refused (web and API).
pub const LOGIN_MAX_FAILED: i64 = 10;
pub const LOGIN_WINDOW_MS: i64 = 15 * 60_000;

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

/// With mail on: always `202 {"verification_required": true}` and no session (nothing
/// tells whether the address had an account). Without mail: `201` with a session, or
/// `409 EMAIL_TAKEN`.
pub async fn register(
    State(st): State<AppState>,
    addr: ClientAddr,
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
    throttle(&st, Bucket::Signup, &addr)?;
    let hash = hash_password_blocking(body.password.clone()).await?;

    if st.mailer.enabled() {
        // Uniform for new, unverified and verified addresses; the session comes from the
        // mailed code (`otp/verify`).
        sign_up_attempt(&st, &email, body.password, hash).await?;
        return Ok((
            StatusCode::ACCEPTED,
            Json(json!({"verification_required": true})),
        ));
    }
    // Without mail (local development) nothing can be verified: sign straight in.
    let id = Uuid::new_v4();
    let now = now_ms();
    match repo::create_user(&st.db, id, &email, &hash, now).await {
        Ok(()) => {}
        Err(DbError::UniqueViolation) => return Err(AppError::EmailTaken),
        Err(e) => return Err(e.into()),
    }
    let user = user_json(id, &email, "free", ts(now), false);
    let json = issue_session(&st, user, id, clean_device(body.device_name)).await?;
    Ok((StatusCode::CREATED, json))
}

pub enum PasswordLogin {
    SignedIn(LoginUser),
    /// Right password, unverified account, mail on: a verification code carrying this
    /// password was mailed; sign-in finishes with that code.
    VerifyFirst,
    Invalid,
    /// Too many failures for this email recently.
    Locked,
}

/// Password sign-in shared by the web and the API; the caller has already spent the
/// per-address `Bucket::Login` budget. The attempt is recorded as failed before the
/// password is checked (and marked succeeded after), so concurrent guesses are all counted.
pub async fn password_login(
    st: &AppState,
    email: &str,
    password: String,
    addr: &str,
) -> AppResult<PasswordLogin> {
    let now = now_ms();
    let (attempt, failed) =
        repo::begin_login_attempt(&st.db, email, Some(addr), now, now - LOGIN_WINDOW_MS).await?;
    if failed > LOGIN_MAX_FAILED {
        return Ok(PasswordLogin::Locked);
    }
    let row = repo::find_user_for_login(&st.db, email).await?;
    let ok = check_password(
        password.clone(),
        row.as_ref().map(|r| r.password_hash.clone()),
    )
    .await?;
    let Some(u) = row.filter(|r| ok && !r.disabled) else {
        return Ok(PasswordLogin::Invalid);
    };
    repo::login_succeeded(&st.db, attempt).await?;
    if st.mailer.enabled() && !u.email_verified {
        send_attempt_code(st, u.id, email, password, u.password_hash);
        return Ok(PasswordLogin::VerifyFirst);
    }
    repo::touch_user(&st.db, u.id, now).await?;
    Ok(PasswordLogin::SignedIn(u))
}

pub async fn login(
    State(st): State<AppState>,
    addr: ClientAddr,
    ApiJson(body): ApiJson<Credentials>,
) -> AppResult<Json<Value>> {
    throttle(&st, Bucket::Login, &addr)?;
    // Anything that can't be a valid email still counts as a failed credential, not a 400.
    let email = body.email.trim().to_lowercase();
    match password_login(&st, &email, body.password, addr.as_str()).await? {
        PasswordLogin::SignedIn(r) => {
            let user = user_json(r.id, &email, &r.plan, ts(r.created_at), r.email_verified);
            issue_session(&st, user, r.id, clean_device(body.device_name)).await
        }
        PasswordLogin::VerifyFirst => Err(AppError::EmailNotVerified),
        PasswordLogin::Invalid => Err(AppError::InvalidCredentials),
        PasswordLogin::Locked => Err(AppError::RateLimited),
    }
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
