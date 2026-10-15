//! Email-delivered one-time codes: email confirmation, password reset and passwordless
//! (OTP) sign-in. Codes are 6 digits, single use, short lived, hashed at rest and limited to
//! a few guesses each. The desktop app has no web UI, so these are codes, not links.
//!
//! Endpoints that take an email address never reveal whether the account exists, and the
//! email is sent from a background task so response timing doesn't either.
//!
//! Unverified accounts hold no credentials while mail is on. The first time an anonymous
//! flow proves the mailbox of such an account (a typed-in verification or sign-in code, or
//! a password reset), the mailbox owner claims it: every session and API token ends and
//! the password becomes the one chosen with the sign-up attempt the code was mailed for
//! (none for a sign-in code), whoever registered the address first.

use axum::Json;
use axum::extract::State;
use axum::http::StatusCode;
use serde::Deserialize;
use serde_json::{Value, json};
use subtle::ConstantTimeEq;
use uuid::Uuid;

use super::ApiJson;
use super::auth::{clean_device, issue_session, normalize_email, user_json};
use crate::auth::{
    AuthUser, Bucket, ClientAddr, UNUSABLE_PASSWORD, generate_code, hash_code,
    hash_password_blocking, throttle, verify_password_blocking,
};
use crate::db::DbError;
use crate::error::{AppError, AppResult};
use crate::mailer::{CodePurpose, code_email};
use crate::repo::{self, Issued, LoginUser, NewCode, now_ms, ts};
use crate::state::AppState;

const MAX_GUESSES: i64 = 5;
const RESEND_COOLDOWN_MS: i64 = 30_000;
const MAX_CODES_PER_HOUR: i64 = 5;

/// Issue and email a code in the background. Silently skips when rate limited.
pub fn send_code(st: &AppState, user_id: Uuid, email: &str, purpose: CodePurpose) {
    spawn_send(st, user_id, email, purpose, None);
}

/// A verification code for one sign-up attempt, or for a password sign-in on an unverified
/// account: it carries that attempt's password (`hash` of `password`), which becomes the
/// account's password if the code claims it. When the resend limits hold the code back and
/// the code already out carries a different password, that one is retired, so the mailbox
/// owner can never confirm with a code that installs someone else's password.
pub fn send_attempt_code(
    st: &AppState,
    user_id: Uuid,
    email: &str,
    password: String,
    hash: String,
) {
    spawn_send(
        st,
        user_id,
        email,
        CodePurpose::VerifyEmail,
        Some((password, hash)),
    );
}

fn spawn_send(
    st: &AppState,
    user_id: Uuid,
    email: &str,
    purpose: CodePurpose,
    attempt: Option<(String, String)>,
) {
    let st = st.clone();
    let email = email.to_string();
    tokio::spawn(async move {
        if let Err(e) = issue_and_send(&st, user_id, &email, purpose, attempt).await {
            tracing::error!(error = %e, purpose = purpose.as_str(), "sending code failed");
        }
    });
}

/// Store a code (one transaction, serialized per user and purpose, see
/// [`repo::issue_code`]) and mail it only after that committed.
async fn issue_and_send(
    st: &AppState,
    user_id: Uuid,
    email: &str,
    purpose: CodePurpose,
    attempt: Option<(String, String)>,
) -> AppResult<()> {
    let now = now_ms();
    let p = purpose.as_str();
    let ttl = st.config.auth_code_ttl_minutes;
    let code = generate_code();
    let id = Uuid::new_v4();
    let code_hash = hash_code(p, user_id, &code);
    let new = NewCode {
        id,
        user_id,
        purpose: p,
        code_hash: &code_hash,
        password_hash: attempt.as_ref().map(|(_, h)| h.as_str()),
        now,
        expires_at: now + ttl * 60_000,
    };
    match repo::issue_code(&st.db, &new, RESEND_COOLDOWN_MS, MAX_CODES_PER_HOUR).await? {
        Issued::Stored => st
            .mailer
            .send(code_email(purpose, email, &code, ttl, &id.to_string()))
            .await
            .map_err(|e| AppError::Internal(e.to_string())),
        Issued::Throttled { live } => {
            if let (Some((password, _)), Some(live)) = (attempt, live)
                && let Some(carried) = live.password_hash
                && !verify_password_blocking(password, carried).await?
            {
                repo::supersede_code(&st.db, live.id, now).await?;
            }
            Ok(())
        }
    }
}

/// What a spent code carried.
pub struct Spent {
    /// The sign-up attempt's password hash, for a verification code that had one.
    pub password_hash: Option<String>,
}

/// Validates a submitted code and spends it. Every failure is the same `InvalidCode`.
pub async fn check_code(
    st: &AppState,
    user_id: Uuid,
    purpose: CodePurpose,
    submitted: &str,
) -> AppResult<Spent> {
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
    Ok(Spent {
        password_hash: live.password_hash,
    })
}

/// Sign in with an emailed code typed in anonymously (web `/verify`, `otp/verify`): a
/// verification code (unverified accounts) or a sign-in code. The first proof for a
/// never-verified account claims it (see the module docs); verified accounts keep their
/// password, sessions and tokens. Returns the account, now verified.
pub async fn sign_in_with_code(st: &AppState, email: &str, code: &str) -> AppResult<LoginUser> {
    let mut u = repo::find_user_for_login(&st.db, email)
        .await?
        .filter(|u| !u.disabled)
        .ok_or(AppError::InvalidCode)?;
    let mut spent = None;
    if !u.email_verified {
        spent = check_code(st, u.id, CodePurpose::VerifyEmail, code)
            .await
            .ok();
    }
    let spent = match spent {
        Some(s) => s,
        None => check_code(st, u.id, CodePurpose::LoginOtp, code).await?,
    };
    let now = now_ms();
    if !u.email_verified {
        let password = spent.password_hash.as_deref().unwrap_or(UNUSABLE_PASSWORD);
        // False when another claim or reset verified it meanwhile; that one stands.
        repo::replace_credentials(&st.db, u.id, password, now, true).await?;
        u.email_verified = true;
    }
    repo::touch_user(&st.db, u.id, now).await?;
    Ok(u)
}

/// Reset a password with an emailed code (web and API). Recovery ends every session and
/// revokes every API token, and confirms the email (the code proved it).
pub async fn reset_password(
    st: &AppState,
    email: &str,
    code: &str,
    new_password: String,
) -> AppResult<Uuid> {
    let u = repo::find_user_for_login(&st.db, email)
        .await?
        .filter(|u| !u.disabled)
        .ok_or(AppError::InvalidCode)?;
    check_code(st, u.id, CodePurpose::ResetPassword, code).await?;
    let hash = hash_password_blocking(new_password).await?;
    repo::replace_credentials(&st.db, u.id, &hash, now_ms(), false).await?;
    Ok(u.id)
}

/// A sign-up attempt while mail is on (`password` already validated, `hash` its argon2
/// hash). The visible outcome is the same for every address: a new account gets a
/// verification code; an unverified one gets a verification code carrying this attempt's
/// password (it does not change until that code claims the account); a verified one gets
/// a sign-in code and keeps its password. No session either way.
pub async fn sign_up_attempt(
    st: &AppState,
    email: &str,
    password: String,
    hash: String,
) -> AppResult<()> {
    let id = Uuid::new_v4();
    match repo::create_user(&st.db, id, email, &hash, now_ms()).await {
        Ok(()) => send_attempt_code(st, id, email, password, hash),
        Err(DbError::UniqueViolation) => match repo::find_user_for_login(&st.db, email).await? {
            Some(u) if u.disabled => {}
            Some(u) if u.email_verified => send_code(st, u.id, email, CodePurpose::LoginOtp),
            Some(u) => send_attempt_code(st, u.id, email, password, hash),
            None => {}
        },
        Err(e) => return Err(e.into()),
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
    addr: ClientAddr,
    user: AuthUser,
) -> AppResult<(StatusCode, Json<Value>)> {
    require_mail(&st)?;
    if user.email_verified {
        return Ok((StatusCode::OK, Json(json!({"status": "already_verified"}))));
    }
    throttle(&st, Bucket::CodeRequest, &addr)?;
    send_code(&st, user.id, &user.email, CodePurpose::VerifyEmail);
    Ok((StatusCode::ACCEPTED, Json(json!({"status": "sent"}))))
}

#[derive(Deserialize)]
pub struct CodeBody {
    code: String,
}

/// Confirmation from an existing session (an unverified account only has one if it signed
/// up while mail was off). Not a claim: credentials stay.
pub async fn verify_confirm(
    State(st): State<AppState>,
    addr: ClientAddr,
    user: AuthUser,
    ApiJson(b): ApiJson<CodeBody>,
) -> AppResult<Json<Value>> {
    if !user.email_verified {
        throttle(&st, Bucket::CodeVerify, &addr)?;
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
    addr: ClientAddr,
    ApiJson(b): ApiJson<EmailBody>,
) -> AppResult<(StatusCode, Json<Value>)> {
    require_mail(&st)?;
    let email = normalize_email(&b.email)?;
    throttle(&st, Bucket::CodeRequest, &addr)?;
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
    addr: ClientAddr,
    ApiJson(b): ApiJson<ResetBody>,
) -> AppResult<StatusCode> {
    let pw_len = b.new_password.chars().count();
    if !(10..=256).contains(&pw_len) {
        return Err(AppError::Invalid(
            "password must be between 10 and 256 characters".into(),
        ));
    }
    throttle(&st, Bucket::CodeVerify, &addr)?;
    let email = b.email.trim().to_lowercase();
    reset_password(&st, &email, &b.code, b.new_password).await?;
    Ok(StatusCode::NO_CONTENT)
}

// ---------- OTP sign-in ----------

pub async fn otp_request(
    State(st): State<AppState>,
    addr: ClientAddr,
    ApiJson(b): ApiJson<EmailBody>,
) -> AppResult<(StatusCode, Json<Value>)> {
    require_mail(&st)?;
    let email = normalize_email(&b.email)?;
    throttle(&st, Bucket::CodeRequest, &addr)?;
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

/// Accepts a verification code (what registration and sign-in on an unverified account
/// mail) as well as a sign-in code.
pub async fn otp_verify(
    State(st): State<AppState>,
    addr: ClientAddr,
    ApiJson(b): ApiJson<OtpVerifyBody>,
) -> AppResult<Json<Value>> {
    throttle(&st, Bucket::CodeVerify, &addr)?;
    let email = b.email.trim().to_lowercase();
    let u = sign_in_with_code(&st, &email, &b.code).await?;
    let user = user_json(u.id, &email, &u.plan, ts(u.created_at), true);
    issue_session(&st, user, u.id, clean_device(b.device_name)).await
}
