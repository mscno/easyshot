//! Tokens, password hashing and the `AuthUser` extractor.

use std::sync::OnceLock;

use argon2::Argon2;
use argon2::password_hash::{
    PasswordHash, PasswordHasher, PasswordVerifier, SaltString, rand_core::OsRng as PhRng,
};
use axum::extract::FromRequestParts;
use axum::http::request::Parts;
use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use chrono::{DateTime, Utc};
use rand::rngs::OsRng;
use rand::{Rng, RngCore};
use sha2::{Digest, Sha256};
use uuid::Uuid;

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

pub async fn hash_password_blocking(password: String) -> Result<String, AppError> {
    tokio::task::spawn_blocking(move || hash_password(&password))
        .await
        .map_err(|e| AppError::Internal(e.to_string()))?
}

pub async fn verify_password_blocking(password: String, hash: String) -> Result<bool, AppError> {
    tokio::task::spawn_blocking(move || verify_password(&password, &hash))
        .await
        .map_err(|e| AppError::Internal(e.to_string()))
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
    }
}
