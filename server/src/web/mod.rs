//! The web presence: Topcoat hosts every HTTP request. The existing axum JSON API (`/v1/*`,
//! `/s/*`, `/healthz`) is mounted unchanged through `TowerRoute`; pages are server-rendered
//! with Topcoat views and enhanced with Datastar (one self-hosted Datastar + Rocket bundle).
//! Topcoat's own reactive runtime is not enabled, so Datastar owns all client-side DOM.

pub mod account;
pub mod assets;
pub mod auth;
pub mod layout;
pub mod settings;
pub mod watch;

use std::time::Duration;

use topcoat::{
    Result,
    context::{Cx, app_context},
    cookie::RouterBuilderCookieExt,
    router::{
        Body, HeaderValue, Method, Next, Router, TrustedProxies,
        error::{bad_request, not_found, too_many_requests, unauthorized},
        header, layer,
        request::{client_ip, headers},
        response::Response,
        tower::TowerRoute,
    },
    session::{self, RouterBuilderSessionExt, SessionConfig, cookie::CookieTokenStore},
};
use uuid::Uuid;

use topcoat::datastar::PatchElements;

use crate::auth::SESSION_TTL_DAYS;
use crate::error::AppError;
use crate::repo::{self, now_ms};
use crate::state::AppState;
use crate::video::live::StreamSlot;
use crate::video::scope::Scope;

/// Build the public router: web pages plus the mounted JSON API.
pub fn router(state: AppState) -> Router {
    let api = crate::routes::router(state.clone());
    let proxies = TrustedProxies::new().nearest(state.config.trusted_proxy_hops);
    Router::builder()
        .app_context(state)
        .trusted_proxies(proxies)
        .cookies()
        .sessions(
            SessionConfig::builder()
                .token_store(CookieTokenStore::new().name("sg_session"))
                .lifetime(Duration::from_secs(SESSION_TTL_DAYS as u64 * 86_400))
                .build(),
        )
        .layer(security_headers)
        .route(TowerRoute::any("/v1/{*rest}", api.clone()))
        .route(TowerRoute::new(Method::GET, "/s/{slug}", api.clone()))
        .route(TowerRoute::new(Method::GET, "/healthz", api))
        .route(assets::serve_static)
        .page(account::landing)
        .page(auth::signup_page)
        .route(auth::signup_submit)
        .page(auth::verify_page)
        .route(auth::verify_submit)
        .route(auth::verify_resend)
        .page(auth::login_page)
        .route(auth::login_submit)
        .page(auth::code_page)
        .route(auth::code_submit)
        .page(auth::forgot_page)
        .route(auth::forgot_submit)
        .route(auth::reset_submit)
        .route(auth::logout)
        .route(settings::account)
        .route(settings::verify_send)
        .route(settings::verify)
        .route(settings::change_password)
        .route(settings::revoke_session)
        .route(settings::revoke_others)
        .route(settings::create_token)
        .route(settings::revoke_token)
        .route(settings::delete_account)
        .route(settings::live)
        .page(account::library)
        .route(account::library_live)
        .route(account::item_rename)
        .route(account::item_visibility)
        .route(account::item_delete)
        .route(account::item_send)
        .page(watch::watch)
        .page(watch::embed)
        .route(watch::unlock)
        .route(watch::media)
        .route(watch::download)
        .route(watch::thumbnail)
        .route(watch::transcript)
        .route(watch::live)
        .route(watch::post_comment)
        .route(watch::post_reaction)
        .route(watch::oembed)
        .build()
}

pub fn state(cx: &Cx) -> &AppState {
    app_context::<AppState>(cx)
}

/// A signed-in web user.
#[derive(Debug, Clone)]
pub struct Member {
    pub user_id: Uuid,
    pub email: String,
    /// The `sessions` row behind the cookie (not the token).
    pub session_id: Uuid,
    pub email_verified: bool,
}

impl Member {
    pub fn name(&self) -> &str {
        self.email.split('@').next().unwrap_or(&self.email)
    }
}

pub fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// The member behind the session cookie, if any. Web sessions live in the same `sessions`
/// table as app sessions, keyed by the hash of Topcoat's token.
pub async fn member(cx: &Cx) -> Result<Option<Member>> {
    let Some(hash) = session::token_hash(cx).await? else {
        return Ok(None);
    };
    let st = state(cx);
    let now = now_ms();
    let Some(r) = repo::find_session(&st.db, &hex(&hash[..]), now)
        .await
        .map_err(AppError::from)
        .web()?
    else {
        return Ok(None);
    };
    // "Last used" on the account page; written at most every few minutes per session.
    if r.last_used_at.is_none_or(|t| now - t > 5 * 60_000) {
        repo::touch_session(&st.db, r.credential_id, now)
            .await
            .map_err(AppError::from)
            .web()?;
    }
    Ok(Some(Member {
        user_id: r.user_id,
        email: r.email,
        session_id: r.credential_id,
        email_verified: r.email_verified,
    }))
}

/// Replace any session on this browser with a fresh one for `user_id` (new token, new
/// row), so a token planted before sign-in never becomes authenticated.
pub async fn start_session(cx: &Cx, user_id: Uuid) -> Result<()> {
    let st = state(cx);
    if let Some(old) = session::stop(cx).await? {
        repo::delete_session_by_hash(&st.db, &hex(&old[..]))
            .await
            .map_err(AppError::from)
            .web()?;
    }
    let s = session::start(cx).await?;
    let now = now_ms();
    let expires = s
        .expires_at
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(now);
    let device = browser_name(cx);
    repo::insert_session(
        &st.db,
        user_id,
        &hex(&s.token_hash[..]),
        Some(&device),
        now,
        expires,
    )
    .await
    .map_err(AppError::from)
    .web()?;
    repo::touch_user(&st.db, user_id, now)
        .await
        .map_err(AppError::from)
        .web()?;
    Ok(())
}

/// A short label for the sessions list: "Safari on macOS", "Chrome on Windows", …
pub fn browser_name(cx: &Cx) -> String {
    let (_, ua) = fingerprint(cx);
    let browser = [
        ("Edg/", "Edge"),
        ("Firefox/", "Firefox"),
        ("Chrome/", "Chrome"),
        ("Safari/", "Safari"),
    ]
    .iter()
    .find(|(k, _)| ua.contains(k))
    .map(|(_, n)| *n)
    .unwrap_or("Browser");
    let os = [
        ("iPhone", "iOS"),
        ("iPad", "iPadOS"),
        ("Android", "Android"),
        ("Mac OS X", "macOS"),
        ("Windows", "Windows"),
        ("Linux", "Linux"),
    ]
    .iter()
    .find(|(k, _)| ua.contains(k))
    .map(|(_, n)| *n);
    match os {
        Some(os) => format!("{browser} on {os}"),
        None => browser.to_string(),
    }
}

/// Live streams one session may hold open at once (tabs × pages).
pub const MAX_STREAMS_PER_SESSION: usize = 12;
/// Anonymous viewers are counted per client address instead.
pub const MAX_STREAMS_PER_ADDRESS: usize = 24;

/// Reserve a live-stream slot for this viewer, or answer 429.
pub fn admit_stream(cx: &Cx, member: &Option<Member>) -> Result<StreamSlot> {
    let (key, max) = match member {
        Some(m) => (format!("s:{}", m.session_id), MAX_STREAMS_PER_SESSION),
        None => (format!("ip:{}", fingerprint(cx).0), MAX_STREAMS_PER_ADDRESS),
    };
    state(cx)
        .live
        .admit(&key, max)
        .ok_or_else(|| too_many_requests(5).into())
}

/// The patch that sends a page whose session ended to sign-in. `next` must be a local path
/// we built (it is placed inside a Datastar expression).
pub fn signed_out_patch(next: &str) -> PatchElements {
    let next: String = next
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || matches!(c, '/' | '-' | '_'))
        .collect();
    PatchElements::new(format!(
        "<div id=\"live-redirect\" hidden data-init=\"window.location.assign('/login?next={next}')\"></div>"
    ))
}

pub fn scope_of(member: &Option<Member>) -> Scope {
    member
        .as_ref()
        .map(|m| Scope::user(m.user_id))
        .unwrap_or_default()
}

/// Client address plus user agent, for rate limits and anonymous view counting.
pub fn fingerprint(cx: &Cx) -> (String, String) {
    let ip = client_ip(cx)
        .map(|ip| ip.to_string())
        .unwrap_or_else(|| "unknown".into());
    let ua = headers(cx)
        .get(header::USER_AGENT)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("")
        .chars()
        .take(200)
        .collect();
    (ip, ua)
}

/// Rate limit a web write by client address; 429 when exceeded.
pub fn limit(cx: &Cx, what: &str, max: u32, window: Duration) -> Result<()> {
    let (ip, _) = fingerprint(cx);
    if state(cx)
        .limiter
        .allow(&format!("{what}:{ip}"), max, window)
    {
        Ok(())
    } else {
        Err(too_many_requests(window.as_secs()).into())
    }
}

/// Map service errors onto web responses without leaking internals.
pub trait WebResult<T> {
    fn web(self) -> Result<T>;
}

impl<T> WebResult<T> for std::result::Result<T, AppError> {
    fn web(self) -> Result<T> {
        self.map_err(|e| match e {
            AppError::NotFound | AppError::Gone => not_found().into(),
            AppError::Unauthorized => unauthorized().into(),
            AppError::RateLimited => too_many_requests(60).into(),
            AppError::Invalid(m) => bad_request(m).into(),
            AppError::TooLarge => topcoat::router::error::content_too_large().into(),
            other => {
                tracing::error!(error = %other, "web request failed");
                topcoat::router::error::internal_server_error(topcoat::Error::from(other)).into()
            }
        })
    }
}

/// Security headers on every response; pages that are meant to be framed set their own CSP.
#[layer("/")]
async fn security_headers(cx: &Cx, body: Body, next: Next<'_>) -> Result<Response> {
    let media = media_origins(state(cx));
    let mut res = next.run(cx, body).await?;
    let h = res.headers_mut();
    if !h.contains_key(header::CONTENT_SECURITY_POLICY) {
        h.insert(header::CONTENT_SECURITY_POLICY, csp(&media, "'none'"));
    }
    h.insert(
        header::X_CONTENT_TYPE_OPTIONS,
        HeaderValue::from_static("nosniff"),
    );
    h.insert(
        header::REFERRER_POLICY,
        HeaderValue::from_static("strict-origin-when-cross-origin"),
    );
    Ok(res)
}

/// Datastar compiles `data-*` expressions with `Function`, hence `'unsafe-eval'`; there are
/// no inline scripts. Media and images may come from the object store's presigned URLs.
pub fn csp(media: &str, frame_ancestors: &str) -> HeaderValue {
    HeaderValue::from_str(&format!(
        "default-src 'self'; script-src 'self' 'unsafe-eval'; style-src 'self'; \
         img-src 'self' data: {media}; media-src 'self' blob: {media}; connect-src 'self'; \
         font-src 'self'; object-src 'none'; base-uri 'none'; form-action 'self'; \
         frame-ancestors {frame_ancestors}"
    ))
    .unwrap_or_else(|_| HeaderValue::from_static("default-src 'self'"))
}

fn media_origins(st: &AppState) -> String {
    // Presigned URLs point at the store; allow https everywhere and a plain-http dev store.
    match st.config.s3_endpoint.as_deref() {
        Some(e) if e.starts_with("http://") => format!("https: {}", e.trim_end_matches('/')),
        _ => "https:".into(),
    }
}
