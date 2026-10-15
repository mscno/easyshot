//! Email-delivered one-time codes: email confirmation, password reset and passwordless
//! (OTP) sign-in. Codes are 6 digits, single use, short lived, hashed at rest and limited to
//! a few guesses each. The desktop app has no web UI, so these are codes, not links.
//!
//! Endpoints that take an email address never reveal whether the account exists, and the
//! email is sent from a background task so response timing doesn't either.

use axum::Json;
use axum::extract::State;
use axum::http::StatusCode;
use serde::Deserialize;
use serde_json::{Value, json};
use subtle::ConstantTimeEq;
use uuid::Uuid;

use super::ApiJson;
use super::auth::{clean_device, issue_session, normalize_email, user_json};
use crate::auth::{AuthUser, generate_code, hash_code, hash_password_blocking};
use crate::error::{AppError, AppResult};
use crate::mailer::{CodePurpose, code_email};
use crate::repo::{self, now_ms, ts};
use crate::state::AppState;

const MAX_GUESSES: i64 = 5;
const RESEND_COOLDOWN_MS: i64 = 30_000;
const MAX_CODES_PER_HOUR: i64 = 5;
const HOUR_MS: i64 = 3_600_000;

/// Issue and email a code in the background. Silently skips when rate limited.
pub fn send_code(st: &AppState, user_id: Uuid, email: &str, purpose: CodePurpose) {
    let st = st.clone();
    let email = email.to_string();
    tokio::spawn(async move {
        if let Err(e) = issue_and_send(&st, user_id, &email, purpose).await {
            tracing::error!(error = %e, purpose = purpose.as_str(), "sending code failed");
        }
    });
}

async fn issue_and_send(
    st: &AppState,
    user_id: Uuid,
    email: &str,
    purpose: CodePurpose,
) -> AppResult<()> {
    let now = now_ms();
    let p = purpose.as_str();
    let state = repo::code_issue_state(&st.db, user_id, p, now - HOUR_MS).await?;
    if state.sent_since >= MAX_CODES_PER_HOUR
        || state
            .last_created_at
            .is_some_and(|t| now - t < RESEND_COOLDOWN_MS)
    {
        return Ok(());
    }
    let ttl = st.config.auth_code_ttl_minutes;
    let code = generate_code();
    let id = Uuid::new_v4();
    repo::insert_code(
        &st.db,
        id,
        user_id,
        p,
        &hash_code(p, user_id, &code),
        now,
        now + ttl * 60_000,
    )
    .await?;
    st.mailer
        .send(code_email(purpose, email, &code, ttl, &id.to_string()))
        .await
        .map_err(|e| AppError::Internal(e.to_string()))
}

/// Validates a submitted code and spends it. Every failure is the same `InvalidCode`.
pub async fn check_code(
    st: &AppState,
    user_id: Uuid,
    purpose: CodePurpose,
    submitted: &str,
) -> AppResult<()> {
    let submitted = submitted.trim();
    if submitted.len() != 6 || !submitted.bytes().all(|b| b.is_ascii_digit()) {
        return Err(AppError::InvalidCode);
    }
    let now = now_ms();
    let p = purpose.as_str();
    let live = repo::live_code(&st.db, user_id, p, now)
        .await?
        .ok_or(AppError::InvalidCode)?;
    if !repo::spend_code_attempt(&st.db, live.id, MAX_GUESSES).await? {
        return Err(AppError::InvalidCode);
    }
    let expected = hash_code(p, user_id, submitted);
    if !bool::from(expected.as_bytes().ct_eq(live.code_hash.as_bytes())) {
        return Err(AppError::InvalidCode);
    }
    if !repo::consume_code(&st.db, live.id, now).await? {
        return Err(AppError::InvalidCode);
    }
    Ok(())
}

fn require_mail(st: &AppState) -> AppResult<()> {
    if st.mailer.enabled() {
        Ok(())
    } else {
        Err(AppError::EmailUnavailable)
    }
}

fn accepted() -> (StatusCode, Json<Value>) {
    (
        StatusCode::ACCEPTED,
        Json(json!({"status": "sent_if_account_exists"})),
    )
}

// ---------- email confirmation ----------

pub async fn verify_send(
    State(st): State<AppState>,
    user: AuthUser,
) -> AppResult<(StatusCode, Json<Value>)> {
    require_mail(&st)?;
    if user.email_verified {
        return Ok((StatusCode::OK, Json(json!({"status": "already_verified"}))));
    }
    send_code(&st, user.id, &user.email, CodePurpose::VerifyEmail);
    Ok((StatusCode::ACCEPTED, Json(json!({"status": "sent"}))))
}

#[derive(Deserialize)]
pub struct CodeBody {
    code: String,
}

pub async fn verify_confirm(
    State(st): State<AppState>,
    user: AuthUser,
    ApiJson(b): ApiJson<CodeBody>,
) -> AppResult<Json<Value>> {
    if !user.email_verified {
        check_code(&st, user.id, CodePurpose::VerifyEmail, &b.code).await?;
        repo::set_email_verified(&st.db, user.id, now_ms()).await?;
    }
    Ok(Json(json!({"email_verified": true})))
}

// ---------- forgot / reset password ----------

#[derive(Deserialize)]
pub struct EmailBody {
    email: String,
}

pub async fn password_forgot(
    State(st): State<AppState>,
    ApiJson(b): ApiJson<EmailBody>,
) -> AppResult<(StatusCode, Json<Value>)> {
    require_mail(&st)?;
    let email = normalize_email(&b.email)?;
    if let Some(u) = repo::find_user_for_login(&st.db, &email).await?
        && !u.disabled
    {
        send_code(&st, u.id, &email, CodePurpose::ResetPassword);
    }
    Ok(accepted())
}

#[derive(Deserialize)]
pub struct ResetBody {
    email: String,
    code: String,
    new_password: String,
}

pub async fn password_reset(
    State(st): State<AppState>,
    ApiJson(b): ApiJson<ResetBody>,
) -> AppResult<StatusCode> {
    let pw_len = b.new_password.chars().count();
    if !(10..=256).contains(&pw_len) {
        return Err(AppError::Invalid(
            "password must be between 10 and 256 characters".into(),
        ));
    }
    let email = b.email.trim().to_lowercase();
    let u = repo::find_user_for_login(&st.db, &email)
        .await?
        .filter(|u| !u.disabled)
        .ok_or(AppError::InvalidCode)?;
    check_code(&st, u.id, CodePurpose::ResetPassword, &b.code).await?;
    let hash = hash_password_blocking(b.new_password).await?;
    let now = now_ms();
    repo::set_password(&st.db, u.id, &hash, now).await?;
    // Knowing the emailed code proves the address; old sessions must not survive a reset.
    repo::set_email_verified(&st.db, u.id, now).await?;
    repo::delete_user_sessions(&st.db, u.id).await?;
    Ok(StatusCode::NO_CONTENT)
}

// ---------- OTP sign-in ----------

pub async fn otp_request(
    State(st): State<AppState>,
    ApiJson(b): ApiJson<EmailBody>,
) -> AppResult<(StatusCode, Json<Value>)> {
    require_mail(&st)?;
    let email = normalize_email(&b.email)?;
    if let Some(u) = repo::find_user_for_login(&st.db, &email).await?
        && !u.disabled
    {
        send_code(&st, u.id, &email, CodePurpose::LoginOtp);
    }
    Ok(accepted())
}

#[derive(Deserialize)]
pub struct OtpVerifyBody {
    email: String,
    code: String,
    device_name: Option<String>,
}

pub async fn otp_verify(
    State(st): State<AppState>,
    ApiJson(b): ApiJson<OtpVerifyBody>,
) -> AppResult<Json<Value>> {
    let email = b.email.trim().to_lowercase();
    let u = repo::find_user_for_login(&st.db, &email)
        .await?
        .filter(|u| !u.disabled)
        .ok_or(AppError::InvalidCode)?;
    check_code(&st, u.id, CodePurpose::LoginOtp, &b.code).await?;
    let now = now_ms();
    repo::touch_user(&st.db, u.id, now).await?;
    repo::set_email_verified(&st.db, u.id, now).await?;
    let user = user_json(u.id, &email, &u.plan, ts(u.created_at), true);
    issue_session(&st, user, u.id, clean_device(b.device_name)).await
}
