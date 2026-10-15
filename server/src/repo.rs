//! The repository layer: raw SQL through the Toasty pool (see `db`); the video domain uses Toasty models.
//! Ids are UUID strings, timestamps epoch milliseconds, booleans 0/1.
//!
//! users, sessions, auth_codes, api_tokens and login_attempts have no row-level-security
//! policy on purpose: they are read before a principal is known (sign-in, token lookup,
//! code checks) and are always filtered by an explicit user id or token hash.

use chrono::{DateTime, TimeZone, Utc};
use uuid::Uuid;

use crate::db::{Context, Db, DbError, DbResult, Row, placeholders, tx_execute, tx_query};
use crate::error::AppResult;
use crate::{orm, vals};

/// Rows per `IN (...)` / `DELETE` statement.
const IN_CHUNK: usize = 200;

pub fn now_ms() -> i64 {
    Utc::now().timestamp_millis()
}

pub fn ts(ms: i64) -> DateTime<Utc> {
    Utc.timestamp_millis_opt(ms).single().unwrap_or_default()
}

// ---------- users ----------

pub struct LoginUser {
    pub id: Uuid,
    pub password_hash: String,
    pub plan: String,
    pub created_at: i64,
    pub disabled: bool,
    pub email_verified: bool,
}

/// `email` must already be lowercase. Duplicate emails yield `DbError::UniqueViolation`.
pub async fn create_user(
    db: &Db,
    id: Uuid,
    email: &str,
    password_hash: &str,
    now: i64,
) -> DbResult<()> {
    db.execute(
        "INSERT INTO users (id, email, password_hash, created_at, updated_at, last_seen_at) \
         VALUES ($1, $2, $3, $4, $4, $4)",
        &vals![id, email, password_hash, now],
    )
    .await?;
    Ok(())
}

pub async fn find_user_for_login(db: &Db, email: &str) -> DbResult<Option<LoginUser>> {
    db.query_opt(
        "SELECT id, password_hash, plan, created_at, disabled_at, email_verified_at FROM users WHERE email = $1",
        &vals![email],
    )
    .await?
    .map(|r| {
        Ok(LoginUser {
            id: r.uuid(0)?,
            password_hash: r.text(1)?,
            plan: r.text(2)?,
            created_at: r.i64(3)?,
            disabled: r.opt_i64(4)?.is_some(),
            email_verified: r.opt_i64(5)?.is_some(),
        })
    })
    .transpose()
}

pub async fn touch_user(db: &Db, id: Uuid, now: i64) -> DbResult<()> {
    db.execute(
        "UPDATE users SET last_seen_at = $2 WHERE id = $1",
        &vals![id, now],
    )
    .await?;
    Ok(())
}

pub async fn set_email_verified(db: &Db, id: Uuid, now: i64) -> DbResult<()> {
    db.execute(
        "UPDATE users SET email_verified_at = COALESCE(email_verified_at, $2), updated_at = $2 WHERE id = $1",
        &vals![id, now],
    )
    .await?;
    Ok(())
}

pub async fn set_password(db: &Db, id: Uuid, password_hash: &str, now: i64) -> DbResult<()> {
    db.execute(
        "UPDATE users SET password_hash = $2, updated_at = $3 WHERE id = $1",
        &vals![id, password_hash, now],
    )
    .await?;
    Ok(())
}

pub async fn delete_user_sessions(db: &Db, user_id: Uuid) -> DbResult<()> {
    db.execute("DELETE FROM sessions WHERE user_id = $1", &vals![user_id])
        .await?;
    Ok(())
}

// ---------- one-time email codes ----------

pub struct NewCode<'a> {
    pub id: Uuid,
    pub user_id: Uuid,
    pub purpose: &'a str,
    pub code_hash: &'a str,
    /// The sign-up attempt's password, installed if this code claims an unverified account.
    pub password_hash: Option<&'a str>,
    pub now: i64,
    pub expires_at: i64,
}

pub enum Issued {
    /// Stored, superseding every earlier live code of this purpose: mail it.
    Stored,
    /// Refused by the resend cooldown or the hourly cap. `live` is the newest still-usable
    /// code, if any, with the password it carries.
    Throttled { live: Option<LiveCode> },
}

/// Issue a code under the per-(user, purpose) rate limits, in one transaction that holds a
/// transaction-level advisory lock on (user, purpose), so concurrent requests are counted
/// one after another: at most one code per `cooldown_ms`, `per_hour` per hour.
pub async fn issue_code(
    db: &Db,
    c: &NewCode<'_>,
    cooldown_ms: i64,
    per_hour: i64,
) -> AppResult<Issued> {
    let mut orm = db.toasty();
    let mut tx = orm::begin(&mut orm, &Context::default()).await?;
    tx_execute(
        &mut tx,
        "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
        &vals![format!("auth_code:{}:{}", c.user_id, c.purpose)],
    )
    .await?;
    let rows = tx_query(
        &mut tx,
        "SELECT MAX(created_at), COUNT(*) FROM auth_codes \
         WHERE user_id = $1 AND purpose = $2 AND created_at >= $3",
        &vals![c.user_id, c.purpose, c.now - 3_600_000],
    )
    .await?;
    let r = rows
        .first()
        .ok_or_else(|| DbError::Other("no aggregate row".into()))?;
    let (last, sent) = (r.opt_i64(0)?, r.i64(1)?);
    if sent >= per_hour || last.is_some_and(|t| c.now - t < cooldown_ms) {
        let live = tx_query(
            &mut tx,
            &format!("{LIVE_CODE} LIMIT 1"),
            &vals![c.user_id, c.purpose, c.now],
        )
        .await?
        .first()
        .map(live_code_row)
        .transpose()?;
        tx.commit().await.map_err(orm::orm_err)?;
        return Ok(Issued::Throttled { live });
    }
    tx_execute(
        &mut tx,
        "UPDATE auth_codes SET consumed_at = $3 \
         WHERE user_id = $1 AND purpose = $2 AND consumed_at IS NULL",
        &vals![c.user_id, c.purpose, c.now],
    )
    .await?;
    tx_execute(
        &mut tx,
        "INSERT INTO auth_codes (id, user_id, purpose, code_hash, password_hash, created_at, expires_at) \
         VALUES ($1, $2, $3, $4, $5, $6, $7)",
        &vals![
            c.id,
            c.user_id,
            c.purpose,
            c.code_hash,
            c.password_hash,
            c.now,
            c.expires_at
        ],
    )
    .await?;
    tx.commit().await.map_err(orm::orm_err)?;
    Ok(Issued::Stored)
}

/// Retire one code early (it carries a password other than the latest attempt's).
pub async fn supersede_code(db: &Db, id: Uuid, now: i64) -> DbResult<()> {
    db.execute(
        "UPDATE auth_codes SET consumed_at = $2 WHERE id = $1 AND consumed_at IS NULL",
        &vals![id, now],
    )
    .await?;
    Ok(())
}

pub struct LiveCode {
    pub id: Uuid,
    pub code_hash: String,
    pub password_hash: Option<String>,
}

const LIVE_CODE: &str = "SELECT id, code_hash, password_hash FROM auth_codes \
     WHERE user_id = $1 AND purpose = $2 AND consumed_at IS NULL AND expires_at > $3 \
     ORDER BY created_at DESC";

fn live_code_row(r: &Row) -> DbResult<LiveCode> {
    Ok(LiveCode {
        id: r.uuid(0)?,
        code_hash: r.text(1)?,
        password_hash: r.opt_text(2)?,
    })
}

pub async fn live_code(
    db: &Db,
    user_id: Uuid,
    purpose: &str,
    now: i64,
) -> DbResult<Option<LiveCode>> {
    db.query_opt(
        &format!("{LIVE_CODE} LIMIT 1"),
        &vals![user_id, purpose, now],
    )
    .await?
    .as_ref()
    .map(live_code_row)
    .transpose()
}

/// Atomically spend one guess; false once `max` guesses were used (or the code is gone).
pub async fn spend_code_attempt(db: &Db, id: Uuid, max: i64) -> DbResult<bool> {
    Ok(db
        .execute(
            "UPDATE auth_codes SET attempts = attempts + 1 \
             WHERE id = $1 AND consumed_at IS NULL AND attempts < $2",
            &vals![id, max],
        )
        .await?
        == 1)
}

/// True for exactly one caller, so a code can't be used twice concurrently. The password a
/// code carried is not kept once it is used.
pub async fn consume_code(db: &Db, id: Uuid, now: i64) -> DbResult<bool> {
    Ok(db
        .execute(
            "UPDATE auth_codes SET consumed_at = $2, password_hash = NULL \
             WHERE id = $1 AND consumed_at IS NULL",
            &vals![id, now],
        )
        .await?
        == 1)
}

/// Replace an account's credentials in one transaction: set `password_hash`, confirm the
/// email, end every session and revoke every API token. Used when an emailed code proves
/// the mailbox anonymously: password reset (`only_unverified = false`) and the first
/// verification of an account that was never verified, its claim (`only_unverified =
/// true`: nothing changes, and false is returned, if the account was verified meanwhile).
pub async fn replace_credentials(
    db: &Db,
    user_id: Uuid,
    password_hash: &str,
    now: i64,
    only_unverified: bool,
) -> AppResult<bool> {
    let mut orm = db.toasty();
    let mut tx = orm::begin(&mut orm, &Context::default()).await?;
    let row = tx_query(
        &mut tx,
        "SELECT email_verified_at FROM users WHERE id = $1 FOR UPDATE",
        &vals![user_id],
    )
    .await?;
    let Some(r) = row.first() else {
        return Ok(false);
    };
    if only_unverified && r.opt_i64(0)?.is_some() {
        return Ok(false);
    }
    tx_execute(
        &mut tx,
        "UPDATE users SET password_hash = $2, email_verified_at = COALESCE(email_verified_at, $3), \
         updated_at = $3 WHERE id = $1",
        &vals![user_id, password_hash, now],
    )
    .await?;
    tx_execute(
        &mut tx,
        "DELETE FROM sessions WHERE user_id = $1",
        &vals![user_id],
    )
    .await?;
    tx_execute(&mut tx, REVOKE_USER_TOKENS, &vals![user_id, now]).await?;
    tx.commit().await.map_err(orm::orm_err)?;
    Ok(true)
}

pub async fn delete_old_codes(db: &Db, expired_before: i64) -> DbResult<u64> {
    db.execute(
        "DELETE FROM auth_codes WHERE expires_at < $1",
        &vals![expired_before],
    )
    .await
}

// ---------- sessions ----------

pub async fn insert_session(
    db: &Db,
    user_id: Uuid,
    token_hash: &str,
    device: Option<&str>,
    now: i64,
    expires_at: i64,
) -> DbResult<()> {
    db.execute(
        "INSERT INTO sessions (id, user_id, token_hash, device_name, created_at, last_used_at, expires_at) \
         VALUES ($1, $2, $3, $4, $5, $5, $6)",
        &vals![Uuid::new_v4(), user_id, token_hash, device, now, expires_at],
    )
    .await?;
    Ok(())
}

pub struct AuthRow {
    /// Session id or API token id.
    pub credential_id: Uuid,
    pub last_used_at: Option<i64>,
    pub user_id: Uuid,
    pub email: String,
    pub plan: String,
    pub created_at: i64,
    pub email_verified: bool,
}

fn auth_row(r: &Row) -> DbResult<AuthRow> {
    Ok(AuthRow {
        credential_id: r.uuid(0)?,
        last_used_at: r.opt_i64(1)?,
        user_id: r.uuid(2)?,
        email: r.text(3)?,
        plan: r.text(4)?,
        created_at: r.i64(5)?,
        email_verified: r.opt_i64(6)?.is_some(),
    })
}

pub async fn find_session(db: &Db, token_hash: &str, now: i64) -> DbResult<Option<AuthRow>> {
    db.query_opt(
        "SELECT s.id, s.last_used_at, u.id, u.email, u.plan, u.created_at, u.email_verified_at \
         FROM sessions s JOIN users u ON u.id = s.user_id \
         WHERE s.token_hash = $1 AND s.expires_at > $2 AND u.disabled_at IS NULL",
        &vals![token_hash, now],
    )
    .await?
    .as_ref()
    .map(auth_row)
    .transpose()
}

pub async fn refresh_session(db: &Db, id: Uuid, now: i64, expires_at: i64) -> DbResult<()> {
    db.execute(
        "UPDATE sessions SET last_used_at = $2, expires_at = $3 WHERE id = $1",
        &vals![id, now, expires_at],
    )
    .await?;
    Ok(())
}

pub async fn delete_session(db: &Db, id: Uuid) -> DbResult<()> {
    db.execute("DELETE FROM sessions WHERE id = $1", &vals![id])
        .await?;
    Ok(())
}

/// Record use without extending the session (web sessions have a fixed cookie lifetime).
pub async fn touch_session(db: &Db, id: Uuid, now: i64) -> DbResult<()> {
    db.execute(
        "UPDATE sessions SET last_used_at = $2 WHERE id = $1",
        &vals![id, now],
    )
    .await?;
    Ok(())
}

pub struct SessionRow {
    pub id: Uuid,
    pub device_name: Option<String>,
    pub created_at: i64,
    pub last_used_at: i64,
}

/// A user's unexpired sessions, most recently used first: Mac app devices and browsers.
pub async fn list_sessions(db: &Db, user_id: Uuid, now: i64) -> DbResult<Vec<SessionRow>> {
    db.query(
        "SELECT id, device_name, created_at, last_used_at FROM sessions \
         WHERE user_id = $1 AND expires_at > $2 ORDER BY last_used_at DESC, id DESC LIMIT 100",
        &vals![user_id, now],
    )
    .await?
    .iter()
    .map(|r| {
        Ok(SessionRow {
            id: r.uuid(0)?,
            device_name: r.opt_text(1)?,
            created_at: r.i64(2)?,
            last_used_at: r.i64(3)?,
        })
    })
    .collect()
}

/// Remove one of the user's sessions; returns whether it existed.
pub async fn delete_user_session(db: &Db, user_id: Uuid, id: Uuid) -> DbResult<bool> {
    Ok(db
        .execute(
            "DELETE FROM sessions WHERE id = $1 AND user_id = $2",
            &vals![id, user_id],
        )
        .await?
        > 0)
}

/// Remove every session of the user except `keep`; returns how many.
pub async fn delete_other_sessions(db: &Db, user_id: Uuid, keep: Uuid) -> DbResult<u64> {
    db.execute(
        "DELETE FROM sessions WHERE user_id = $1 AND id <> $2",
        &vals![user_id, keep],
    )
    .await
}

pub async fn delete_session_by_hash(db: &Db, token_hash: &str) -> DbResult<()> {
    db.execute(
        "DELETE FROM sessions WHERE token_hash = $1",
        &vals![token_hash],
    )
    .await?;
    Ok(())
}

/// Email of an active user (for showing who shared a video).
pub async fn user_email(db: &Db, id: &str) -> DbResult<Option<String>> {
    db.query_opt(
        "SELECT email FROM users WHERE id = $1 AND disabled_at IS NULL",
        &vals![id],
    )
    .await?
    .map(|r| r.text(0))
    .transpose()
}

pub async fn delete_expired_sessions(db: &Db, now: i64) -> DbResult<u64> {
    db.execute("DELETE FROM sessions WHERE expires_at < $1", &vals![now])
        .await
}

// ---------- api tokens ----------

pub async fn insert_api_token(
    db: &Db,
    id: Uuid,
    user_id: Uuid,
    name: &str,
    token_hash: &str,
    now: i64,
) -> DbResult<()> {
    db.execute(
        "INSERT INTO api_tokens (id, user_id, name, token_hash, created_at) VALUES ($1, $2, $3, $4, $5)",
        &vals![id, user_id, name, token_hash, now],
    )
    .await?;
    Ok(())
}

pub async fn find_api_token(db: &Db, token_hash: &str) -> DbResult<Option<AuthRow>> {
    db.query_opt(
        "SELECT t.id, t.last_used_at, u.id, u.email, u.plan, u.created_at, u.email_verified_at \
         FROM api_tokens t JOIN users u ON u.id = t.user_id \
         WHERE t.token_hash = $1 AND t.revoked_at IS NULL AND u.disabled_at IS NULL",
        &vals![token_hash],
    )
    .await?
    .as_ref()
    .map(auth_row)
    .transpose()
}

pub async fn touch_api_token(db: &Db, id: Uuid, now: i64) -> DbResult<()> {
    db.execute(
        "UPDATE api_tokens SET last_used_at = $2 WHERE id = $1",
        &vals![id, now],
    )
    .await?;
    Ok(())
}

pub struct TokenRow {
    pub id: Uuid,
    pub name: String,
    pub created_at: i64,
    pub last_used_at: Option<i64>,
}

pub async fn list_api_tokens(db: &Db, user_id: Uuid) -> DbResult<Vec<TokenRow>> {
    db.query(
        "SELECT id, name, created_at, last_used_at FROM api_tokens \
         WHERE user_id = $1 AND revoked_at IS NULL ORDER BY created_at DESC, id DESC",
        &vals![user_id],
    )
    .await?
    .iter()
    .map(|r| {
        Ok(TokenRow {
            id: r.uuid(0)?,
            name: r.text(1)?,
            created_at: r.i64(2)?,
            last_used_at: r.opt_i64(3)?,
        })
    })
    .collect()
}

/// Returns whether a token was revoked.
pub async fn revoke_api_token(db: &Db, id: Uuid, user_id: Uuid, now: i64) -> DbResult<bool> {
    Ok(db
        .execute(
            "UPDATE api_tokens SET revoked_at = $3 WHERE id = $1 AND user_id = $2 AND revoked_at IS NULL",
            &vals![id, user_id, now],
        )
        .await?
        > 0)
}

const REVOKE_USER_TOKENS: &str =
    "UPDATE api_tokens SET revoked_at = $2 WHERE user_id = $1 AND revoked_at IS NULL";

/// Revoke every API token of a user; returns how many.
pub async fn revoke_user_api_tokens(db: &Db, user_id: Uuid, now: i64) -> DbResult<u64> {
    db.execute(REVOKE_USER_TOKENS, &vals![user_id, now]).await
}

// ---------- login attempts ----------

pub async fn count_failed_logins(db: &Db, email: &str, since: i64) -> DbResult<i64> {
    db.query_one(
        "SELECT count(*) FROM login_attempts WHERE email = $1 AND succeeded = 0 AND created_at > $2",
        &vals![email, since],
    )
    .await?
    .i64(0)
}

/// Record a password sign-in attempt as failed *before* checking it, then count the
/// failures since `since` including it. Every concurrent guess is counted by the time any
/// of them is checked, so a burst cannot exceed the per-account limit. Returns the
/// attempt's id (see [`login_succeeded`]) and the failure count.
pub async fn begin_login_attempt(
    db: &Db,
    email: &str,
    ip: Option<&str>,
    now: i64,
    since: i64,
) -> DbResult<(Uuid, i64)> {
    let id = Uuid::new_v4();
    db.execute(
        "INSERT INTO login_attempts (id, email, ip, succeeded, created_at) VALUES ($1, $2, $3, 0, $4)",
        &vals![id, email, ip, now],
    )
    .await?;
    Ok((id, count_failed_logins(db, email, since).await?))
}

pub async fn login_succeeded(db: &Db, id: Uuid) -> DbResult<()> {
    db.execute(
        "UPDATE login_attempts SET succeeded = 1 WHERE id = $1",
        &vals![id],
    )
    .await?;
    Ok(())
}

pub async fn delete_old_login_attempts(db: &Db, before: i64) -> DbResult<u64> {
    db.execute(
        "DELETE FROM login_attempts WHERE created_at < $1",
        &vals![before],
    )
    .await
}

// ---------- screenshots ----------
//
// `screenshots` is owner-scoped and under FORCE'd row-level security (migration
// 0004_rls_app_role). Every function here sets its RLS context itself: the owner's id,
// the one share slug being resolved, or the marked maintenance bypass.

pub struct Screenshot {
    pub id: Uuid,
    pub slug: String,
    pub object_key: String,
    pub content_type: String,
    pub byte_size: i64,
    pub width: Option<i64>,
    pub height: Option<i64>,
    pub filename: Option<String>,
    pub status: String,
    pub created_at: i64,
    pub expires_at: i64,
}

const COLS: &str = "id, slug, object_key, content_type, byte_size, width, height, filename, status, created_at, expires_at";

fn screenshot(r: &Row) -> DbResult<Screenshot> {
    Ok(Screenshot {
        id: r.uuid(0)?,
        slug: r.text(1)?,
        object_key: r.text(2)?,
        content_type: r.text(3)?,
        byte_size: r.i64(4)?,
        width: r.opt_i64(5)?,
        height: r.opt_i64(6)?,
        filename: r.opt_text(7)?,
        status: r.text(8)?,
        created_at: r.i64(9)?,
        expires_at: r.i64(10)?,
    })
}

pub struct NewScreenshot<'a> {
    pub id: Uuid,
    pub user_id: Uuid,
    pub slug: &'a str,
    pub object_key: &'a str,
    pub content_type: &'a str,
    pub byte_size: i64,
    pub width: Option<i32>,
    pub height: Option<i32>,
    pub filename: Option<&'a str>,
    pub now: i64,
    pub expires_at: i64,
}

/// Returns false when the slug is already taken (caller retries with another slug).
pub async fn insert_screenshot(db: &Db, s: &NewScreenshot<'_>) -> DbResult<bool> {
    Ok(db
        .scoped(Context::user(s.user_id))
        .execute(
            "INSERT INTO screenshots (id, user_id, slug, object_key, content_type, byte_size, width, height, filename, created_at, expires_at) \
             VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11) ON CONFLICT (slug) DO NOTHING",
            &vals![
                s.id,
                s.user_id,
                s.slug,
                s.object_key,
                s.content_type,
                s.byte_size,
                s.width,
                s.height,
                s.filename,
                s.now,
                s.expires_at
            ],
        )
        .await?
        > 0)
}

pub async fn get_screenshot(db: &Db, id: Uuid, user_id: Uuid) -> DbResult<Option<Screenshot>> {
    db.scoped(Context::user(user_id))
        .query_opt(
            &format!("SELECT {COLS} FROM screenshots WHERE id = $1 AND user_id = $2"),
            &vals![id, user_id],
        )
        .await?
        .as_ref()
        .map(screenshot)
        .transpose()
}

pub async fn mark_ready(db: &Db, id: Uuid, user_id: Uuid, now: i64) -> DbResult<()> {
    db.scoped(Context::user(user_id))
        .execute(
        "UPDATE screenshots SET status = 'ready', uploaded_at = $2 WHERE id = $1 AND status = 'pending'",
        &vals![id, now],
    )
    .await?;
    Ok(())
}

pub async fn delete_screenshot(db: &Db, id: Uuid, user_id: Uuid) -> DbResult<()> {
    db.scoped(Context::user(user_id))
        .execute(
            "DELETE FROM screenshots WHERE id = $1 AND user_id = $2",
            &vals![id, user_id],
        )
        .await?;
    Ok(())
}

/// Ready, unexpired screenshots newest first; `before` is a (created_at, id) keyset cursor.
pub async fn list_ready(
    db: &Db,
    user_id: Uuid,
    now: i64,
    before: Option<(i64, Uuid)>,
    limit: i64,
) -> DbResult<Vec<Screenshot>> {
    let mut sql = format!(
        "SELECT {COLS} FROM screenshots WHERE user_id = $1 AND status = 'ready' AND expires_at > $2"
    );
    let mut params = vals![user_id, now].to_vec();
    if let Some((created, id)) = before {
        sql.push_str(" AND (created_at < $3 OR (created_at = $3 AND id < $4))");
        params.push(created.into());
        params.push(id.into());
    }
    sql.push_str(&format!(
        " ORDER BY created_at DESC, id DESC LIMIT ${}",
        params.len() + 1
    ));
    params.push(limit.into());
    db.scoped(Context::user(user_id))
        .query(&sql, &params)
        .await?
        .iter()
        .map(screenshot)
        .collect()
}

/// (count, total bytes) of a user's ready, unexpired screenshots.
pub async fn usage(db: &Db, user_id: Uuid, now: i64) -> DbResult<(i64, i64)> {
    let r = db
        .scoped(Context::user(user_id))
        .query_one(
            "SELECT count(*), CAST(COALESCE(SUM(byte_size), 0) AS BIGINT) FROM screenshots \
             WHERE user_id = $1 AND status = 'ready' AND expires_at > $2",
            &vals![user_id, now],
        )
        .await?;
    Ok((r.i64(0)?, r.i64(1)?))
}

/// (object_key, content_type, expires_at) of a ready screenshot by slug.
/// RLS share path: the context names exactly this slug, so only its row is readable.
pub async fn find_share(db: &Db, slug: &str) -> DbResult<Option<(String, String, i64)>> {
    db.scoped(Context {
        share_slug: Some(slug.to_string()),
        ..Context::default()
    })
    .query_opt(
        "SELECT object_key, content_type, expires_at FROM screenshots WHERE slug = $1 AND status = 'ready'",
        &vals![slug],
    )
    .await?
    .map(|r| Ok((r.text(0)?, r.text(1)?, r.i64(2)?)))
    .transpose()
}

// ---------- expiry ----------

/// (id, object_key) pairs.
pub type KeyedIds = Vec<(Uuid, String)>;

fn keyed(rows: Vec<Row>) -> DbResult<KeyedIds> {
    rows.iter().map(|r| Ok((r.uuid(0)?, r.text(1)?))).collect()
}

pub async fn expired_screenshots(db: &Db, now: i64, limit: i64) -> DbResult<KeyedIds> {
    keyed(
        db.scoped(Context::maintenance()).query(
            "SELECT id, object_key FROM screenshots WHERE expires_at <= $1 ORDER BY expires_at LIMIT $2",
            &vals![now, limit],
        )
        .await?,
    )
}

pub async fn stale_pending_screenshots(db: &Db, before: i64, limit: i64) -> DbResult<KeyedIds> {
    keyed(
        db.scoped(Context::maintenance()).query(
            "SELECT id, object_key FROM screenshots WHERE status = 'pending' AND created_at < $1 \
             ORDER BY created_at LIMIT $2",
            &vals![before, limit],
        )
        .await?,
    )
}

/// Idempotent; chunks the id list into bounded `IN (...)` statements.
pub async fn delete_screenshots_by_ids(db: &Db, ids: &[Uuid]) -> DbResult<()> {
    let db = db.scoped(Context::maintenance());
    for chunk in ids.chunks(IN_CHUNK) {
        let sql = format!(
            "DELETE FROM screenshots WHERE id IN ({})",
            placeholders(1, chunk.len())
        );
        let params: Vec<_> = chunk.iter().map(|i| (*i).into()).collect();
        db.execute(&sql, &params).await?;
    }
    Ok(())
}

pub async fn inactive_users(db: &Db, last_seen_before: i64, limit: i64) -> DbResult<Vec<Uuid>> {
    db.query(
        "SELECT id FROM users WHERE last_seen_at < $1 ORDER BY last_seen_at LIMIT $2",
        &vals![last_seen_before, limit],
    )
    .await?
    .iter()
    .map(|r| r.uuid(0))
    .collect()
}

pub async fn user_screenshots(db: &Db, user_id: Uuid, limit: i64) -> DbResult<KeyedIds> {
    keyed(
        db.scoped(Context::user(user_id))
            .query(
                "SELECT id, object_key FROM screenshots WHERE user_id = $1 LIMIT $2",
                &vals![user_id, limit],
            )
            .await?,
    )
}

/// Remove a user's sessions, API tokens, login attempts and finally the user row.
/// (Their screenshots must already be gone.) No FK cascades are relied upon.
pub async fn delete_user_records(db: &Db, user_id: Uuid) -> DbResult<()> {
    db.execute(
        "DELETE FROM login_attempts WHERE email IN (SELECT email FROM users WHERE id = $1)",
        &vals![user_id],
    )
    .await?;
    db.execute("DELETE FROM sessions WHERE user_id = $1", &vals![user_id])
        .await?;
    db.execute("DELETE FROM auth_codes WHERE user_id = $1", &vals![user_id])
        .await?;
    db.execute("DELETE FROM api_tokens WHERE user_id = $1", &vals![user_id])
        .await?;
    db.execute("DELETE FROM users WHERE id = $1", &vals![user_id])
        .await?;
    Ok(())
}
