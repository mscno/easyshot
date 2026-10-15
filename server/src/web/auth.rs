//! Web sign-up and sign-in: plain HTML forms with full-page responses (303 on success), so
//! they work without JavaScript. They reuse the API's rules and stores: argon2 passwords,
//! `login_attempts` throttling, emailed one-time codes (verification, sign-in, reset) and
//! the shared `sessions` table. Every successful sign-in starts a fresh session token.

use std::future::Future;

use serde::Deserialize;
use topcoat::{
    Result,
    context::Cx,
    router::{
        HeaderValue, StatusCode,
        content::Form,
        error::{redirect, see_other, too_many_requests},
        header, page, query_params,
        response::{IntoResponse, Response},
        route,
    },
    session,
    view::{View, ViewExt, component, view},
};
use uuid::Uuid;

use super::layout::{Meta, shell};
use super::{WebResult, fingerprint, hex, member, start_session, state};
use crate::auth::{Bucket, allow, hash_password_blocking};
use crate::db::DbError;
use crate::error::AppError;
use crate::mailer::CodePurpose;
use crate::repo::{self, now_ms};
use crate::routes::auth::{PasswordLogin, normalize_email, password_login};
use crate::routes::codes::{reset_password, send_code, sign_in_with_code, sign_up_attempt};

pub const MIN_PASSWORD: usize = 10;
pub const MAX_PASSWORD: usize = 256;

/// Same rule as the API (`/v1/auth/register`, `/v1/auth/password/reset`).
pub fn password_problem(pw: &str) -> Option<String> {
    let n = pw.chars().count();
    (!(MIN_PASSWORD..=MAX_PASSWORD).contains(&n))
        .then(|| format!("Use a password of {MIN_PASSWORD} to {MAX_PASSWORD} characters."))
}

/// Only local destinations we serve after sign-in.
pub fn safe_next(next: Option<&str>) -> String {
    match next {
        Some(n)
            if (n.starts_with("/v/") || n == "/library" || n == "/account")
                && n.bytes()
                    .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'/' | b'-' | b'_')) =>
        {
            n.to_string()
        }
        _ => "/library".into(),
    }
}

#[query_params]
pub struct AuthQuery {
    next: Option<String>,
    email: Option<String>,
}

fn query(cx: &Cx) -> (String, String) {
    let q = query_params::<AuthQuery>(cx).ok();
    let next = safe_next(q.as_ref().and_then(|q| q.next.as_deref()));
    let email = q
        .and_then(|q| q.email.clone())
        .unwrap_or_default()
        .chars()
        .take(254)
        .collect();
    (next, email)
}

/// Spend one hit of this client address's auth budget (shared with the API); 429 when spent.
pub fn throttle(cx: &Cx, bucket: Bucket) -> Result<()> {
    let st = state(cx);
    if allow(st, bucket, &fingerprint(cx).0) {
        Ok(())
    } else {
        Err(too_many_requests(bucket.limit(st).window_secs).into())
    }
}

/// Signed-in visitors skip the sign-in pages.
async fn already_signed_in(cx: &Cx, next: &str) -> Result<()> {
    if member(cx).await?.is_some() {
        return Err(redirect(next).into());
    }
    Ok(())
}

fn html(body: String, status: StatusCode) -> Response {
    let mut res = Response::new(body.into());
    *res.status_mut() = status;
    res.headers_mut().insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static("text/html; charset=utf-8"),
    );
    res
}

#[component]
async fn card(
    title: &'static str,
    error: Option<String>,
    child: topcoat::view::Child<'_>,
) -> Result<impl View> {
    Ok(view! {
        shell(
            meta: Meta { noindex: true, ..Meta::titled(title) },
            signed_in: false,
            <section class="card narrow auth">
                <h1>(title)</h1>
                match error {
                    Some(e) => <p class="notice error" role="alert">(e)</p>,
                    None => "",
                }
                (child)
            </section>
        )
    })
}

// ---------- sign up ----------

#[component]
async fn signup_form(
    next: String,
    email: String,
    error: Option<String>,
    open: bool,
) -> Result<impl View> {
    Ok(view! {
        card(
            title: "Create your account",
            error: error,
            if open {
                <form method="post" action="/signup" class="stack">
                    <input type="hidden" name="next" value=(next.as_str())>
                    <label for="email">"Email"</label>
                    <input
                        id="email"
                        name="email"
                        type="email"
                        value=(email.as_str())
                        required=""
                        autocomplete="email"
                        autofocus=""
                    >
                    <label for="password">"Password"</label>
                    <input
                        id="password"
                        name="password"
                        type="password"
                        minlength="10"
                        maxlength="256"
                        required=""
                        autocomplete="new-password"
                        aria-describedby="password-help"
                    >
                    <p id="password-help" class="muted small">
                        "At least 10 characters."
                    </p>
                    <button type="submit" class="button primary">
                        "Create account"
                    </button>
                </form>
            } else {
                <p class="muted">"Sign-ups are closed on this server."</p>
            }
            <p class="muted small">
                "Already have an account? "
                <a href="/login">"Sign in"</a>
            </p>
        )
    })
}

#[page("/signup")]
pub async fn signup_page(cx: &Cx) -> Result<impl View> {
    let (next, email) = query(cx);
    already_signed_in(cx, &next).await?;
    let open = state(cx).config.allow_signups;
    Ok(view! { signup_form(next: next, email: email, error: None, open: open) })
}

#[derive(Deserialize)]
pub struct SignupForm {
    email: String,
    password: String,
    next: Option<String>,
}

#[route(POST "/signup")]
pub async fn signup_submit(cx: &Cx, Form(f): Form<SignupForm>) -> Result<Response> {
    let next = safe_next(f.next.as_deref());
    let st = state(cx);
    let fail_next = next.clone();
    let fail = |email: String, msg: String, status| {
        let next = fail_next.clone();
        async move {
            let body = view! {
                cx =>
                signup_form(next: next, email: email, error: Some(msg), open: true)
            }
            .single()
            .await?
            .render(cx);
            Ok::<Response, topcoat::Error>(html(body, status))
        }
    };
    if !st.config.allow_signups {
        let msg = "Sign-ups are closed on this server.".into();
        return fail(f.email, msg, StatusCode::FORBIDDEN).await;
    }
    let Ok(email) = normalize_email(&f.email) else {
        let msg = "Enter a valid email address.".into();
        return fail(f.email, msg, StatusCode::UNPROCESSABLE_ENTITY).await;
    };
    if let Some(p) = password_problem(&f.password) {
        return fail(email, p, StatusCode::UNPROCESSABLE_ENTITY).await;
    }
    throttle(cx, Bucket::Signup)?;
    let hash = hash_password_blocking(f.password.clone()).await.web()?;
    if st.mailer.enabled() {
        // Same answer whether or not the address has an account (see `sign_up_attempt`):
        // the mailed code confirms a new or unverified account with this password, or signs
        // a verified owner in.
        sign_up_attempt(st, &email, f.password, hash).await.web()?;
    } else {
        // No mail configured (local development): nothing to verify with.
        let id = Uuid::new_v4();
        match repo::create_user(&st.db, id, &email, &hash, now_ms()).await {
            Ok(()) => {
                start_session(cx, id).await?;
                return see_other(next).into_response(cx);
            }
            Err(DbError::UniqueViolation) => {
                return fail(
                    email,
                    "An account with this email already exists. Sign in instead.".into(),
                    StatusCode::CONFLICT,
                )
                .await;
            }
            Err(e) => return Err(AppError::from(e)).web(),
        }
    }
    let body = view! {
        cx =>
        code_form(next: next, email: email, error: None, resent: false)
    }
    .single()
    .await?
    .render(cx);
    Ok(html(body, StatusCode::OK))
}

// ---------- verify (after sign-up, or an emailed sign-in code) ----------

#[component]
async fn code_form(
    next: String,
    email: String,
    error: Option<String>,
    resent: bool,
) -> Result<impl View> {
    Ok(view! {
        card(
            title: "Check your email",
            error: error,
            <p class="muted">
                "We sent a 6-digit code to "
                <strong>(email.as_str())</strong>
                ". It expires in a few minutes."
            </p>
            if resent {
                <p class="notice" role="status">"A new code is on its way."</p>
            }
            <form method="post" action="/verify" class="stack">
                <input type="hidden" name="next" value=(next.as_str())>
                <input type="hidden" name="email" value=(email.as_str())>
                <label for="code">"Code"</label>
                <input
                    id="code"
                    name="code"
                    inputmode="numeric"
                    pattern="[0-9]{6}"
                    maxlength="6"
                    required=""
                    autocomplete="one-time-code"
                    autofocus=""
                >
                <button type="submit" class="button primary">"Continue"</button>
            </form>
            <form method="post" action="/verify/resend" class="inline">
                <input type="hidden" name="next" value=(next.as_str())>
                <input type="hidden" name="email" value=(email.as_str())>
                <button type="submit" class="link">"Send a new code"</button>
            </form>
        )
    })
}

#[page("/verify")]
pub async fn verify_page(cx: &Cx) -> Result<impl View> {
    let (next, email) = query(cx);
    Ok(view! { code_form(next: next, email: email, error: None, resent: false) })
}

#[derive(Deserialize)]
pub struct CodeForm {
    email: String,
    code: String,
    next: Option<String>,
}

/// Accepts a verification code (new accounts) or a sign-in code (existing accounts, or the
/// "email me a code" sign-in), then signs in with a fresh session. The first code for an
/// account that was never verified claims it (`sign_in_with_code`): every earlier session
/// and API token ends.
#[route(POST "/verify")]
pub async fn verify_submit(cx: &Cx, Form(f): Form<CodeForm>) -> Result<Response> {
    let next = safe_next(f.next.as_deref());
    let st = state(cx);
    let email = f.email.trim().to_lowercase();
    throttle(cx, Bucket::CodeVerify)?;
    let u = match sign_in_with_code(st, &email, &f.code).await {
        Ok(u) => u,
        Err(AppError::InvalidCode) => {
            let body = view! {
                cx =>
                code_form(
                    next: next,
                    email: email,
                    error: Some("That code is not valid or has expired.".into()),
                    resent: false
                )
            }
            .single()
            .await?
            .render(cx);
            return Ok(html(body, StatusCode::UNPROCESSABLE_ENTITY));
        }
        Err(e) => return Err(e).web(),
    };
    start_session(cx, u.id).await?;
    see_other(next).into_response(cx)
}

#[derive(Deserialize)]
pub struct EmailForm {
    email: String,
    next: Option<String>,
}

#[route(POST "/verify/resend")]
pub async fn verify_resend(cx: &Cx, Form(f): Form<EmailForm>) -> Result<Response> {
    let next = safe_next(f.next.as_deref());
    let st = state(cx);
    let email = f.email.trim().to_lowercase();
    throttle(cx, Bucket::CodeRequest)?;
    // A resent verification code carries no password: if it claims the account, the
    // password is set again through a reset.
    if st.mailer.enabled()
        && let Some(u) = repo::find_user_for_login(&st.db, &email)
            .await
            .map_err(Into::into)
            .web()?
        && !u.disabled
    {
        let purpose = if u.email_verified {
            CodePurpose::LoginOtp
        } else {
            CodePurpose::VerifyEmail
        };
        send_code(st, u.id, &email, purpose);
    }
    let body = view! {
        cx =>
        code_form(next: next, email: email, error: None, resent: true)
    }
    .single()
    .await?
    .render(cx);
    Ok(html(body, StatusCode::OK))
}

// ---------- sign in with a password ----------

#[component]
async fn login_form(
    next: String,
    email: String,
    error: Option<String>,
    mail: bool,
) -> Result<impl View> {
    let code_url = format!("/login/code?next={next}");
    let signup_url = format!("/signup?next={next}");
    Ok(view! {
        card(
            title: "Sign in",
            error: error,
            <form method="post" action="/login" class="stack">
                <input type="hidden" name="next" value=(next.as_str())>
                <label for="email">"Email"</label>
                <input
                    id="email"
                    name="email"
                    type="email"
                    value=(email.as_str())
                    required=""
                    autocomplete="username"
                    autofocus=""
                >
                <label for="password">"Password"</label>
                <input
                    id="password"
                    name="password"
                    type="password"
                    required=""
                    autocomplete="current-password"
                >
                <button type="submit" class="button primary">"Sign in"</button>
            </form>
            if mail {
                <p class="row small">
                    <a href=(code_url.as_str())>"Email me a sign-in code"</a>
                    <a href="/forgot">"Forgot password?"</a>
                </p>
            }
            <p class="muted small">
                "New to Easyshot? "
                <a href=(signup_url.as_str())>"Create an account"</a>
            </p>
        )
    })
}

#[page("/login")]
pub async fn login_page(cx: &Cx) -> Result<impl View> {
    let (next, email) = query(cx);
    already_signed_in(cx, &next).await?;
    let mail = state(cx).mailer.enabled();
    Ok(view! { login_form(next: next, email: email, error: None, mail: mail) })
}

#[derive(Deserialize)]
pub struct LoginForm {
    email: String,
    password: String,
    next: Option<String>,
}

/// Same rules as the API (`password_login`): the per-address budget, then the per-email
/// lockout. An unverified account (mail on) gets a verification code instead of a session.
#[route(POST "/login")]
pub async fn login_submit(cx: &Cx, Form(f): Form<LoginForm>) -> Result<Response> {
    let next = safe_next(f.next.as_deref());
    let st = state(cx);
    let email = f.email.trim().to_lowercase();
    let mail = st.mailer.enabled();
    throttle(cx, Bucket::Login)?;
    let fail = |msg: &str, status| {
        let (next, email, msg) = (next.clone(), email.clone(), msg.to_string());
        async move {
            let body = view! {
                cx =>
                login_form(next: next, email: email, error: Some(msg), mail: mail)
            }
            .single()
            .await?
            .render(cx);
            Ok::<Response, topcoat::Error>(html(body, status))
        }
    };
    let (ip, _) = fingerprint(cx);
    let u = match password_login(st, &email, f.password, &ip).await.web()? {
        PasswordLogin::SignedIn(u) => u,
        PasswordLogin::VerifyFirst => {
            let body = view! {
                cx =>
                code_form(next: next, email: email, error: None, resent: false)
            }
            .single()
            .await?
            .render(cx);
            return Ok(html(body, StatusCode::OK));
        }
        PasswordLogin::Invalid => {
            return fail(
                "That email and password do not match.",
                StatusCode::UNPROCESSABLE_ENTITY,
            )
            .await;
        }
        PasswordLogin::Locked => {
            return fail(
                "Too many attempts. Try again in 15 minutes, or sign in with an emailed code.",
                StatusCode::TOO_MANY_REQUESTS,
            )
            .await;
        }
    };
    start_session(cx, u.id).await?;
    see_other(next).into_response(cx)
}

// ---------- sign in with an emailed code ----------

#[component]
async fn code_request_form(
    next: String,
    email: String,
    error: Option<String>,
) -> Result<impl View> {
    Ok(view! {
        card(
            title: "Sign in with a code",
            error: error,
            <p class="muted">"We'll email you a 6-digit code."</p>
            <form method="post" action="/login/code" class="stack">
                <input type="hidden" name="next" value=(next.as_str())>
                <label for="email">"Email"</label>
                <input
                    id="email"
                    name="email"
                    type="email"
                    value=(email.as_str())
                    required=""
                    autocomplete="email"
                    autofocus=""
                >
                <button type="submit" class="button primary">"Email me a code"</button>
            </form>
            <p class="muted small"><a href="/login">"Sign in with a password"</a></p>
        )
    })
}

#[page("/login/code")]
pub async fn code_page(cx: &Cx) -> Result<impl View> {
    let (next, email) = query(cx);
    already_signed_in(cx, &next).await?;
    let error = (!state(cx).mailer.enabled())
        .then(|| "Email sign-in is not configured on this server.".to_string());
    Ok(view! { code_request_form(next: next, email: email, error: error) })
}

#[route(POST "/login/code")]
pub async fn code_submit(cx: &Cx, Form(f): Form<EmailForm>) -> Result<Response> {
    let next = safe_next(f.next.as_deref());
    let st = state(cx);
    let Ok(email) = normalize_email(&f.email) else {
        let body = view! {
            cx =>
            code_request_form(
                next: next,
                email: f.email,
                error: Some("Enter a valid email address.".into())
            )
        }
        .single()
        .await?
        .render(cx);
        return Ok(html(body, StatusCode::UNPROCESSABLE_ENTITY));
    };
    throttle(cx, Bucket::CodeRequest)?;
    if st.mailer.enabled()
        && let Some(u) = repo::find_user_for_login(&st.db, &email)
            .await
            .map_err(Into::into)
            .web()?
        && !u.disabled
    {
        send_code(st, u.id, &email, CodePurpose::LoginOtp);
    }
    let body = view! {
        cx =>
        code_form(next: next, email: email, error: None, resent: false)
    }
    .single()
    .await?
    .render(cx);
    Ok(html(body, StatusCode::OK))
}

// ---------- forgot / reset password ----------

#[component]
async fn forgot_form(email: String, error: Option<String>) -> Result<impl View> {
    Ok(view! {
        card(
            title: "Reset your password",
            error: error,
            <p class="muted">"We'll email you a code to choose a new password."</p>
            <form method="post" action="/forgot" class="stack">
                <label for="email">"Email"</label>
                <input
                    id="email"
                    name="email"
                    type="email"
                    value=(email.as_str())
                    required=""
                    autocomplete="email"
                    autofocus=""
                >
                <button type="submit" class="button primary">"Email me a code"</button>
            </form>
        )
    })
}

#[component]
async fn reset_form(email: String, error: Option<String>) -> Result<impl View> {
    Ok(view! {
        card(
            title: "Choose a new password",
            error: error,
            <p class="muted">
                "If "
                <strong>(email.as_str())</strong>
                " has an account, a code is on its way."
            </p>
            <form method="post" action="/reset" class="stack">
                <input type="hidden" name="email" value=(email.as_str())>
                <label for="code">"Code"</label>
                <input
                    id="code"
                    name="code"
                    inputmode="numeric"
                    pattern="[0-9]{6}"
                    maxlength="6"
                    required=""
                    autocomplete="one-time-code"
                    autofocus=""
                >
                <label for="password">"New password"</label>
                <input
                    id="password"
                    name="password"
                    type="password"
                    minlength="10"
                    maxlength="256"
                    required=""
                    autocomplete="new-password"
                >
                <button type="submit" class="button primary">"Save and sign in"</button>
            </form>
        )
    })
}

#[page("/forgot")]
pub async fn forgot_page(cx: &Cx) -> Result<impl View> {
    let (_, email) = query(cx);
    let error = (!state(cx).mailer.enabled())
        .then(|| "Email is not configured on this server.".to_string());
    Ok(view! { forgot_form(email: email, error: error) })
}

#[route(POST "/forgot")]
pub async fn forgot_submit(cx: &Cx, Form(f): Form<EmailForm>) -> Result<Response> {
    let st = state(cx);
    let Ok(email) = normalize_email(&f.email) else {
        let body = view! {
            cx =>
            forgot_form(
                email: f.email,
                error: Some("Enter a valid email address.".into())
            )
        }
        .single()
        .await?
        .render(cx);
        return Ok(html(body, StatusCode::UNPROCESSABLE_ENTITY));
    };
    throttle(cx, Bucket::CodeRequest)?;
    if st.mailer.enabled()
        && let Some(u) = repo::find_user_for_login(&st.db, &email)
            .await
            .map_err(Into::into)
            .web()?
        && !u.disabled
    {
        send_code(st, u.id, &email, CodePurpose::ResetPassword);
    }
    let body = view! { cx => reset_form(email: email, error: None) }
        .single()
        .await?
        .render(cx);
    Ok(html(body, StatusCode::OK))
}

#[derive(Deserialize)]
pub struct ResetForm {
    email: String,
    code: String,
    password: String,
}

#[route(POST "/reset")]
pub async fn reset_submit(cx: &Cx, Form(f): Form<ResetForm>) -> Result<Response> {
    let st = state(cx);
    let email = f.email.trim().to_lowercase();
    throttle(cx, Bucket::CodeVerify)?;
    let fail = |msg: String| {
        let email = email.clone();
        async move {
            let body = view! { cx => reset_form(email: email, error: Some(msg)) }
                .single()
                .await?
                .render(cx);
            Ok::<Response, topcoat::Error>(html(body, StatusCode::UNPROCESSABLE_ENTITY))
        }
    };
    if let Some(p) = password_problem(&f.password) {
        return fail(p).await;
    }
    // Every existing session (including other devices) and API token ends with a reset.
    let user_id = match reset_password(st, &email, &f.code, f.password).await {
        Ok(id) => id,
        Err(AppError::InvalidCode) => {
            return fail("That code is not valid or has expired.".into()).await;
        }
        Err(e) => return Err(e).web(),
    };
    start_session(cx, user_id).await?;
    see_other("/library").into_response(cx)
}

// ---------- sign out ----------

#[route(POST "/logout")]
pub async fn logout(cx: &Cx) -> Result<Response> {
    if let Some(hash) = session::stop(cx).await? {
        repo::delete_session_by_hash(&state(cx).db, &hex(&hash[..]))
            .await
            .map_err(Into::into)
            .web()?;
    }
    see_other("/").into_response(cx)
}
