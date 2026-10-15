//! Tokens, password hashing and the `AuthUser` extractor.

use std::convert::Infallible;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
use std::sync::{Arc, OnceLock};
use std::time::Duration;

use argon2::Argon2;
use argon2::password_hash::{
    PasswordHash, PasswordHasher, PasswordVerifier, SaltString, rand_core::OsRng as PhRng,
};
use axum::extract::FromRequestParts;
use axum::http::HeaderMap;
use axum::http::request::Parts;
use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use chrono::{DateTime, Utc};
use rand::rngs::OsRng;
use rand::{Rng, RngCore};
use sha2::{Digest, Sha256};
use tokio::sync::Semaphore;
use uuid::Uuid;

use crate::config::Limit;
use crate::error::AppError;
use crate::repo::{self, ts};
use crate::state::AppState;

pub const SESSION_PREFIX: &str = "sgs_";
pub const API_PREFIX: &str = "sgp_";
pub const SESSION_TTL_DAYS: i64 = 30;
/// Session/API-token bookkeeping (and `users.last_seen_at`) is refreshed at most this often.
const TOUCH_INTERVAL_MS: i64 = 3_600_000;
pub const SESSION_TTL_MS: i64 = SESSION_TTL_DAYS * 86_400_000;

/// Returns `(plaintext_token, sha256_hex_hash)`.
pub fn generate_token(prefix: &str) -> (String, String) {
    let mut bytes = [0u8; 32];
    OsRng.fill_bytes(&mut bytes);
    let token = format!("{prefix}{}", URL_SAFE_NO_PAD.encode(bytes));
    let hash = hash_token(&token);
    (token, hash)
}

/// Uniform 6-digit code.
pub fn generate_code() -> String {
    format!("{:06}", OsRng.gen_range(0..1_000_000))
}

/// Codes are short, so bind the hash to who/what it is for.
pub fn hash_code(purpose: &str, user_id: Uuid, code: &str) -> String {
    hash_token(&format!("{purpose}:{user_id}:{code}"))
}

/// Lowercase hex sha256, the stored form of a token.
pub fn hash_token(token: &str) -> String {
    Sha256::digest(token.as_bytes())
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

const BASE62: &[u8] = b"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";

pub fn generate_slug() -> String {
    (0..12)
        .map(|_| BASE62[OsRng.gen_range(0..62)] as char)
        .collect()
}

/// Stored for accounts that have no password (claimed through an emailed sign-in code):
/// not a PHC string, so it never verifies.
pub const UNUSABLE_PASSWORD: &str = "!";

pub fn hash_password(password: &str) -> Result<String, AppError> {
    let salt = SaltString::generate(&mut PhRng);
    Argon2::default()
        .hash_password(password.as_bytes(), &salt)
        .map(|h| h.to_string())
        .map_err(|e| AppError::Internal(format!("hash: {e}")))
}

pub fn verify_password(password: &str, hash: &str) -> bool {
    match PasswordHash::new(hash) {
        Ok(h) => Argon2::default()
            .verify_password(password.as_bytes(), &h)
            .is_ok(),
        Err(_) => false,
    }
}

/// A valid argon2 hash of a random password, used to equalise timing for unknown emails.
pub fn dummy_hash() -> &'static str {
    static H: OnceLock<String> = OnceLock::new();
    H.get_or_init(|| hash_password("dummy-password-for-timing").expect("hash"))
}

/// Argon2 costs ~19 MiB and tens of milliseconds per call; at most this many run at once per
/// process, so a burst of sign-ins queues instead of exhausting memory and blocking threads.
fn argon_permits() -> Arc<Semaphore> {
    static S: OnceLock<Arc<Semaphore>> = OnceLock::new();
    S.get_or_init(|| {
        let n = std::thread::available_parallelism().map_or(2, |n| n.get());
        Arc::new(Semaphore::new(n.max(2)))
    })
    .clone()
}

async fn argon<T: Send + 'static>(f: impl FnOnce() -> T + Send + 'static) -> Result<T, AppError> {
    let permit = argon_permits()
        .acquire_owned()
        .await
        .map_err(|e| AppError::Internal(e.to_string()))?;
    // The permit lives with the blocking work, even if the request is dropped meanwhile.
    tokio::task::spawn_blocking(move || {
        let _permit = permit;
        f()
    })
    .await
    .map_err(|e| AppError::Internal(e.to_string()))
}

pub async fn hash_password_blocking(password: String) -> Result<String, AppError> {
    argon(move || hash_password(&password)).await?
}

pub async fn verify_password_blocking(password: String, hash: String) -> Result<bool, AppError> {
    argon(move || verify_password(&password, &hash)).await
}

/// Check a sign-in password against the stored hash, if any. Unknown accounts and unusable
/// passwords spend the same Argon2 work on the dummy hash, so timing reveals neither.
pub async fn check_password(password: String, stored: Option<String>) -> Result<bool, AppError> {
    let usable = stored.filter(|h| PasswordHash::new(h).is_ok());
    let real = usable.is_some();
    let hash = usable.unwrap_or_else(|| dummy_hash().to_string());
    Ok(verify_password_blocking(password, hash).await? && real)
}

// ---------- per-address throttling (shared by the web pages and the API) ----------

/// Auth budgets per client address; web pages and API endpoints count into the same ones.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Bucket {
    Login,
    Signup,
    CodeRequest,
    CodeVerify,
}

impl Bucket {
    pub fn limit(self, st: &AppState) -> Limit {
        let l = &st.config.auth_limits;
        match self {
            Bucket::Login => l.login,
            Bucket::Signup => l.signup,
            Bucket::CodeRequest => l.code_request,
            Bucket::CodeVerify => l.code_verify,
        }
    }

    fn name(self) -> &'static str {
        match self {
            Bucket::Login => "login",
            Bucket::Signup => "signup",
            Bucket::CodeRequest => "code",
            Bucket::CodeVerify => "verify",
        }
    }
}

/// Count one hit for `addr` (see [`ClientAddr`]); false once its budget is spent.
pub fn allow(st: &AppState, bucket: Bucket, addr: &str) -> bool {
    let l = bucket.limit(st);
    st.limiter.allow(
        &format!("{}:{addr}", bucket.name()),
        l.max,
        Duration::from_secs(l.window_secs),
    )
}

/// [`allow`] for the API: `429 RATE_LIMITED` once the budget is spent.
pub fn throttle(st: &AppState, bucket: Bucket, addr: &ClientAddr) -> Result<(), AppError> {
    if allow(st, bucket, addr.as_str()) {
        Ok(())
    } else {
        Err(AppError::RateLimited)
    }
}

/// The client address of an API request, resolved like the web's (Topcoat
/// `TrustedProxies::nearest(TRUSTED_PROXY_HOPS)`): the peer when no proxy is trusted,
/// otherwise the address the outermost trusted proxy appended to `X-Forwarded-For`, never
/// the client-written leftmost entry. `"unknown"` (one shared bucket) when there is none,
/// as in the web's `fingerprint`.
pub struct ClientAddr(pub String);

impl ClientAddr {
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl FromRequestParts<AppState> for ClientAddr {
    type Rejection = Infallible;

    async fn from_request_parts(parts: &mut Parts, st: &AppState) -> Result<Self, Infallible> {
        // Topcoat hands the mounted API the request's extensions, peer address included.
        let remote = parts
            .extensions
            .get::<topcoat::router::RemoteAddr>()
            .map(|r| r.0.ip());
        Ok(ClientAddr(
            client_ip(remote, &parts.headers, st.config.trusted_proxy_hops)
                .map_or_else(|| "unknown".into(), |ip| ip.to_string()),
        ))
    }
}

/// Topcoat's `TrustedProxies::client_ip` for a hop count (crate-private there): walk
/// `X-Forwarded-For` from the entry nearest to us outward and return the first one past the
/// trusted hops; when the list is shorter, the farthest read (the peer without a header).
pub fn client_ip(remote: Option<IpAddr>, headers: &HeaderMap, hops: usize) -> Option<IpAddr> {
    let remote = remote.map(|ip| ip.to_canonical());
    if hops == 0 {
        return remote;
    }
    let entries = headers
        .get_all("x-forwarded-for")
        .iter()
        .rev()
        .flat_map(|v| {
            v.as_bytes()
                .split(|&b| b == b',')
                .map(<[u8]>::trim_ascii)
                .filter(|e| !e.is_empty())
                .rev()
        });
    let mut farthest = remote;
    for (i, entry) in entries.enumerate() {
        let address = std::str::from_utf8(entry).ok().and_then(parse_node);
        if i + 1 >= hops {
            return address;
        }
        farthest = address;
    }
    farthest
}

/// An address with an optional port: `1.2.3.4`, `1.2.3.4:80`, `::1`, `[::1]`, `[::1]:80`.
fn parse_node(value: &str) -> Option<IpAddr> {
    if let Ok(ip) = value.parse::<IpAddr>() {
        return Some(ip.to_canonical());
    }
    let (ip, port) = if let Some(rest) = value.strip_prefix('[') {
        let (ip, rest) = rest.split_once(']')?;
        let ip = IpAddr::V6(ip.parse::<Ipv6Addr>().ok()?);
        if rest.is_empty() {
            return Some(ip.to_canonical());
        }
        (ip, rest.strip_prefix(':')?)
    } else {
        let (ip, port) = value.rsplit_once(':')?;
        (IpAddr::V4(ip.parse::<Ipv4Addr>().ok()?), port)
    };
    let port_ok = match port.strip_prefix('_') {
        Some(o) => {
            !o.is_empty()
                && o.chars()
                    .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
        }
        None => (1..=5).contains(&port.len()) && port.bytes().all(|b| b.is_ascii_digit()),
    };
    port_ok.then(|| ip.to_canonical())
}

#[derive(Debug, Clone)]
pub struct AuthUser {
    pub id: Uuid,
    pub email: String,
    pub plan: String,
    pub created_at: DateTime<Utc>,
    pub email_verified: bool,
    /// Set when authenticated with a session token (used by logout).
    pub session_id: Option<Uuid>,
}

pub fn bearer_token(parts: &Parts) -> Option<&str> {
    let v = parts
        .headers
        .get(axum::http::header::AUTHORIZATION)?
        .to_str()
        .ok()?;
    let (scheme, tok) = v.split_once(' ')?;
    if scheme.eq_ignore_ascii_case("bearer") && !tok.trim().is_empty() {
        Some(tok.trim())
    } else {
        None
    }
}

impl FromRequestParts<AppState> for AuthUser {
    type Rejection = AppError;

    async fn from_request_parts(parts: &mut Parts, state: &AppState) -> Result<Self, AppError> {
        let token = bearer_token(parts).ok_or(AppError::Unauthorized)?;
        let hash = hash_token(token);
        let now = repo::now_ms();

        let (r, session_id) = if token.starts_with(SESSION_PREFIX) {
            let r = repo::find_session(&state.db, &hash, now)
                .await?
                .ok_or(AppError::Unauthorized)?;
            if now - r.last_used_at.unwrap_or(0) > TOUCH_INTERVAL_MS {
                repo::refresh_session(&state.db, r.credential_id, now, now + SESSION_TTL_MS)
                    .await?;
                repo::touch_user(&state.db, r.user_id, now).await?;
            }
            let sid = r.credential_id;
            (r, Some(sid))
        } else if token.starts_with(API_PREFIX) {
            let r = repo::find_api_token(&state.db, &hash)
                .await?
                .ok_or(AppError::Unauthorized)?;
            if r.last_used_at.is_none_or(|t| now - t > TOUCH_INTERVAL_MS) {
                repo::touch_api_token(&state.db, r.credential_id, now).await?;
                repo::touch_user(&state.db, r.user_id, now).await?;
            }
            (r, None)
        } else {
            return Err(AppError::Unauthorized);
        };
        Ok(AuthUser {
            id: r.user_id,
            email: r.email,
            plan: r.plan,
            created_at: ts(r.created_at),
            email_verified: r.email_verified,
            session_id,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn token_shape_and_hash() {
        let (t, h) = generate_token(SESSION_PREFIX);
        assert!(t.starts_with("sgs_"));
        assert_eq!(t.len(), 4 + 43);
        assert_eq!(h.len(), 64);
        assert!(
            h.chars()
                .all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase())
        );
        assert_eq!(h, hash_token(&t));
        let (t2, _) = generate_token(API_PREFIX);
        assert!(t2.starts_with("sgp_"));
        assert_ne!(t, generate_token(SESSION_PREFIX).0);
    }

    #[test]
    fn slug_shape() {
        let s = generate_slug();
        assert_eq!(s.len(), 12);
        assert!(s.chars().all(|c| c.is_ascii_alphanumeric()));
        assert_ne!(s, generate_slug());
    }

    #[test]
    fn password_roundtrip() {
        let h = hash_password("correct horse battery").unwrap();
        assert!(h.starts_with("$argon2id$"));
        assert!(verify_password("correct horse battery", &h));
        assert!(!verify_password("wrong", &h));
        assert!(!verify_password("", UNUSABLE_PASSWORD));
        assert!(!verify_password("!", UNUSABLE_PASSWORD));
    }

    #[tokio::test]
    async fn unusable_and_missing_passwords_fail() {
        let h = hash_password_blocking("correct horse battery".into())
            .await
            .unwrap();
        let ok = |pw: &str, h: Option<&str>| check_password(pw.into(), h.map(str::to_string));
        assert!(ok("correct horse battery", Some(&h)).await.unwrap());
        assert!(!ok("wrong one", Some(&h)).await.unwrap());
        assert!(!ok("!", Some(UNUSABLE_PASSWORD)).await.unwrap());
        assert!(!ok("dummy-password-for-timing", None).await.unwrap());
    }

    #[test]
    fn client_ip_trusts_only_the_configured_hops() {
        let peer: Option<IpAddr> = Some("10.0.0.9".parse().unwrap());
        let ip = |h: &HeaderMap, n| client_ip(peer, h, n).map(|i| i.to_string());
        let mut h = HeaderMap::new();
        h.insert("x-forwarded-for", "6.6.6.6, 203.0.113.7".parse().unwrap());
        // No trusted proxy: the peer, whatever the header claims.
        assert_eq!(ip(&h, 0).as_deref(), Some("10.0.0.9"));
        assert_eq!(client_ip(None, &h, 0), None);
        // One proxy (Fly): the entry it appended, not the client-written leftmost one.
        assert_eq!(ip(&h, 1).as_deref(), Some("203.0.113.7"));
        assert_eq!(ip(&h, 2).as_deref(), Some("6.6.6.6"));
        // Fewer entries than hops: the farthest; no header: the peer.
        assert_eq!(ip(&h, 5).as_deref(), Some("6.6.6.6"));
        assert_eq!(ip(&HeaderMap::new(), 1).as_deref(), Some("10.0.0.9"));
        // Ports, brackets and repeated headers (the last is nearest).
        let mut h = HeaderMap::new();
        h.append("x-forwarded-for", "6.6.6.6".parse().unwrap());
        let near = "[2001:db8::1]:443, 198.51.100.4:8080";
        h.append("x-forwarded-for", near.parse().unwrap());
        assert_eq!(ip(&h, 1).as_deref(), Some("198.51.100.4"));
        assert_eq!(ip(&h, 2).as_deref(), Some("2001:db8::1"));
        assert_eq!(ip(&h, 3).as_deref(), Some("6.6.6.6"));
        // An unreadable entry at the trusted position names no one.
        let mut h = HeaderMap::new();
        h.insert("x-forwarded-for", "1.2.3.4, garbage".parse().unwrap());
        assert_eq!(ip(&h, 1), None);
    }
}
