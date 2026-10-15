//! All SQL of the app, written once in the portable dialect (see `db`).
//! Ids are UUID strings, timestamps epoch milliseconds, booleans 0/1.

use chrono::{DateTime, TimeZone, Utc};
use uuid::Uuid;

use crate::db::{placeholders, Db, DbResult, Row};
use crate::vals;

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
         VALUES (?1, ?2, ?3, ?4, ?4, ?4)",
        &vals![id, email, password_hash, now],
    )
    .await?;
    Ok(())
}

pub async fn find_user_for_login(db: &Db, email: &str) -> DbResult<Option<LoginUser>> {
    db.query_opt(
        "SELECT id, password_hash, plan, created_at, disabled_at, email_verified_at FROM users WHERE email = ?1",
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
        "UPDATE users SET last_seen_at = ?2 WHERE id = ?1",
        &vals![id, now],
    )
    .await?;
    Ok(())
}

pub async fn set_email_verified(db: &Db, id: Uuid, now: i64) -> DbResult<()> {
    db.execute(
        "UPDATE users SET email_verified_at = COALESCE(email_verified_at, ?2), updated_at = ?2 WHERE id = ?1",
        &vals![id, now],
    )
    .await?;
    Ok(())
}

pub async fn set_password(db: &Db, id: Uuid, password_hash: &str, now: i64) -> DbResult<()> {
    db.execute(
        "UPDATE users SET password_hash = ?2, updated_at = ?3 WHERE id = ?1",
        &vals![id, password_hash, now],
    )
    .await?;
    Ok(())
}

pub async fn delete_user_sessions(db: &Db, user_id: Uuid) -> DbResult<()> {
    db.execute("DELETE FROM sessions WHERE user_id = ?1", &vals![user_id])
        .await?;
    Ok(())
}

// ---------- one-time email codes ----------

pub struct CodeIssueState {
    pub last_created_at: Option<i64>,
    pub sent_since: i64,
}

/// Rate-limit inputs: newest code time and how many were issued since `since`.
pub async fn code_issue_state(
    db: &Db,
    user_id: Uuid,
    purpose: &str,
    since: i64,
) -> DbResult<CodeIssueState> {
    let r = db
        .query_one(
            "SELECT MAX(created_at), COUNT(*) FROM auth_codes \
             WHERE user_id = ?1 AND purpose = ?2 AND created_at >= ?3",
            &vals![user_id, purpose, since],
        )
        .await?;
    Ok(CodeIssueState {
        last_created_at: r.opt_i64(0)?,
        sent_since: r.i64(1)?,
    })
}

/// Supersede any live code of this purpose, then store the new one.
pub async fn insert_code(
    db: &Db,
    id: Uuid,
    user_id: Uuid,
    purpose: &str,
    code_hash: &str,
    now: i64,
    expires_at: i64,
) -> DbResult<()> {
    db.execute(
        "UPDATE auth_codes SET consumed_at = ?3 WHERE user_id = ?1 AND purpose = ?2 AND consumed_at IS NULL",
        &vals![user_id, purpose, now],
    )
    .await?;
    db.execute(
        "INSERT INTO auth_codes (id, user_id, purpose, code_hash, created_at, expires_at) \
         VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
        &vals![id, user_id, purpose, code_hash, now, expires_at],
    )
    .await?;
    Ok(())
}

pub struct LiveCode {
    pub id: Uuid,
    pub code_hash: String,
}

pub async fn live_code(
    db: &Db,
    user_id: Uuid,
    purpose: &str,
    now: i64,
) -> DbResult<Option<LiveCode>> {
    db.query_opt(
        "SELECT id, code_hash FROM auth_codes \
         WHERE user_id = ?1 AND purpose = ?2 AND consumed_at IS NULL AND expires_at > ?3 \
         ORDER BY created_at DESC LIMIT 1",
        &vals![user_id, purpose, now],
    )
    .await?
    .map(|r| {
        Ok(LiveCode {
            id: r.uuid(0)?,
            code_hash: r.text(1)?,
        })
    })
    .transpose()
}

/// Atomically spend one guess; false once `max` guesses were used (or the code is gone).
pub async fn spend_code_attempt(db: &Db, id: Uuid, max: i64) -> DbResult<bool> {
    Ok(db
        .execute(
            "UPDATE auth_codes SET attempts = attempts + 1 \
             WHERE id = ?1 AND consumed_at IS NULL AND attempts < ?2",
            &vals![id, max],
        )
        .await?
        == 1)
}

/// True for exactly one caller, so a code can't be used twice concurrently.
pub async fn consume_code(db: &Db, id: Uuid, now: i64) -> DbResult<bool> {
    Ok(db
        .execute(
            "UPDATE auth_codes SET consumed_at = ?2 WHERE id = ?1 AND consumed_at IS NULL",
            &vals![id, now],
        )
        .await?
        == 1)
}

pub async fn delete_old_codes(db: &Db, expired_before: i64) -> DbResult<u64> {
    db.execute(
        "DELETE FROM auth_codes WHERE expires_at < ?1",
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
         VALUES (?1, ?2, ?3, ?4, ?5, ?5, ?6)",
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
         WHERE s.token_hash = ?1 AND s.expires_at > ?2 AND u.disabled_at IS NULL",
        &vals![token_hash, now],
    )
    .await?
    .as_ref()
    .map(auth_row)
    .transpose()
}

pub async fn refresh_session(db: &Db, id: Uuid, now: i64, expires_at: i64) -> DbResult<()> {
    db.execute(
        "UPDATE sessions SET last_used_at = ?2, expires_at = ?3 WHERE id = ?1",
        &vals![id, now, expires_at],
    )
    .await?;
    Ok(())
}

pub async fn delete_session(db: &Db, id: Uuid) -> DbResult<()> {
    db.execute("DELETE FROM sessions WHERE id = ?1", &vals![id])
        .await?;
    Ok(())
}

pub async fn delete_expired_sessions(db: &Db, now: i64) -> DbResult<u64> {
    db.execute("DELETE FROM sessions WHERE expires_at < ?1", &vals![now])
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
        "INSERT INTO api_tokens (id, user_id, name, token_hash, created_at) VALUES (?1, ?2, ?3, ?4, ?5)",
        &vals![id, user_id, name, token_hash, now],
    )
    .await?;
    Ok(())
}

pub async fn find_api_token(db: &Db, token_hash: &str) -> DbResult<Option<AuthRow>> {
    db.query_opt(
        "SELECT t.id, t.last_used_at, u.id, u.email, u.plan, u.created_at, u.email_verified_at \
         FROM api_tokens t JOIN users u ON u.id = t.user_id \
         WHERE t.token_hash = ?1 AND t.revoked_at IS NULL AND u.disabled_at IS NULL",
        &vals![token_hash],
    )
    .await?
    .as_ref()
    .map(auth_row)
    .transpose()
}

pub async fn touch_api_token(db: &Db, id: Uuid, now: i64) -> DbResult<()> {
    db.execute(
        "UPDATE api_tokens SET last_used_at = ?2 WHERE id = ?1",
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
         WHERE user_id = ?1 AND revoked_at IS NULL ORDER BY created_at DESC, id DESC",
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
            "UPDATE api_tokens SET revoked_at = ?3 WHERE id = ?1 AND user_id = ?2 AND revoked_at IS NULL",
            &vals![id, user_id, now],
        )
        .await?
        > 0)
}

// ---------- login attempts ----------

pub async fn count_failed_logins(db: &Db, email: &str, since: i64) -> DbResult<i64> {
    db.query_one(
        "SELECT count(*) FROM login_attempts WHERE email = ?1 AND succeeded = 0 AND created_at > ?2",
        &vals![email, since],
    )
    .await?
    .i64(0)
}

pub async fn record_login_attempt(
    db: &Db,
    email: &str,
    ip: Option<String>,
    succeeded: bool,
    now: i64,
) -> DbResult<()> {
    db.execute(
        "INSERT INTO login_attempts (id, email, ip, succeeded, created_at) VALUES (?1, ?2, ?3, ?4, ?5)",
        &vals![Uuid::new_v4(), email, ip, succeeded, now],
    )
    .await?;
    Ok(())
}

pub async fn delete_old_login_attempts(db: &Db, before: i64) -> DbResult<u64> {
    db.execute(
        "DELETE FROM login_attempts WHERE created_at < ?1",
        &vals![before],
    )
    .await
}

// ---------- screenshots ----------

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
        .execute(
            "INSERT INTO screenshots (id, user_id, slug, object_key, content_type, byte_size, width, height, filename, created_at, expires_at) \
             VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11) ON CONFLICT (slug) DO NOTHING",
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
    db.query_opt(
        &format!("SELECT {COLS} FROM screenshots WHERE id = ?1 AND user_id = ?2"),
        &vals![id, user_id],
    )
    .await?
    .as_ref()
    .map(screenshot)
    .transpose()
}

pub async fn mark_ready(db: &Db, id: Uuid, now: i64) -> DbResult<()> {
    db.execute(
        "UPDATE screenshots SET status = 'ready', uploaded_at = ?2 WHERE id = ?1 AND status = 'pending'",
        &vals![id, now],
    )
    .await?;
    Ok(())
}

pub async fn delete_screenshot(db: &Db, id: Uuid, user_id: Uuid) -> DbResult<()> {
    db.execute(
        "DELETE FROM screenshots WHERE id = ?1 AND user_id = ?2",
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
        "SELECT {COLS} FROM screenshots WHERE user_id = ?1 AND status = 'ready' AND expires_at > ?2"
    );
    let mut params = vals![user_id, now].to_vec();
    if let Some((created, id)) = before {
        sql.push_str(" AND (created_at < ?3 OR (created_at = ?3 AND id < ?4))");
        params.push(created.into());
        params.push(id.into());
    }
    sql.push_str(&format!(
        " ORDER BY created_at DESC, id DESC LIMIT ?{}",
        params.len() + 1
    ));
    params.push(limit.into());
    db.query(&sql, &params)
        .await?
        .iter()
        .map(screenshot)
        .collect()
}

/// (count, total bytes) of a user's ready, unexpired screenshots.
pub async fn usage(db: &Db, user_id: Uuid, now: i64) -> DbResult<(i64, i64)> {
    let r = db
        .query_one(
            "SELECT count(*), CAST(COALESCE(SUM(byte_size), 0) AS BIGINT) FROM screenshots \
             WHERE user_id = ?1 AND status = 'ready' AND expires_at > ?2",
            &vals![user_id, now],
        )
        .await?;
    Ok((r.i64(0)?, r.i64(1)?))
}

/// (object_key, content_type, expires_at) of a ready screenshot by slug.
pub async fn find_share(db: &Db, slug: &str) -> DbResult<Option<(String, String, i64)>> {
    db.query_opt(
        "SELECT object_key, content_type, expires_at FROM screenshots WHERE slug = ?1 AND status = 'ready'",
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
        db.query(
            "SELECT id, object_key FROM screenshots WHERE expires_at <= ?1 ORDER BY expires_at LIMIT ?2",
            &vals![now, limit],
        )
        .await?,
    )
}

pub async fn stale_pending_screenshots(db: &Db, before: i64, limit: i64) -> DbResult<KeyedIds> {
    keyed(
        db.query(
            "SELECT id, object_key FROM screenshots WHERE status = 'pending' AND created_at < ?1 \
             ORDER BY created_at LIMIT ?2",
            &vals![before, limit],
        )
        .await?,
    )
}

/// Idempotent; chunks the id list into bounded `IN (...)` statements.
pub async fn delete_screenshots_by_ids(db: &Db, ids: &[Uuid]) -> DbResult<()> {
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
        "SELECT id FROM users WHERE last_seen_at < ?1 ORDER BY last_seen_at LIMIT ?2",
        &vals![last_seen_before, limit],
    )
    .await?
    .iter()
    .map(|r| r.uuid(0))
    .collect()
}

pub async fn user_screenshots(db: &Db, user_id: Uuid, limit: i64) -> DbResult<KeyedIds> {
    keyed(
        db.query(
            "SELECT id, object_key FROM screenshots WHERE user_id = ?1 LIMIT ?2",
            &vals![user_id, limit],
        )
        .await?,
    )
}

/// Remove a user's sessions, API tokens, login attempts and finally the user row.
/// (Their screenshots must already be gone.) No FK cascades are relied upon.
pub async fn delete_user_records(db: &Db, user_id: Uuid) -> DbResult<()> {
    db.execute(
        "DELETE FROM login_attempts WHERE email IN (SELECT email FROM users WHERE id = ?1)",
        &vals![user_id],
    )
    .await?;
    db.execute("DELETE FROM sessions WHERE user_id = ?1", &vals![user_id])
        .await?;
    db.execute("DELETE FROM auth_codes WHERE user_id = ?1", &vals![user_id])
        .await?;
    db.execute("DELETE FROM api_tokens WHERE user_id = ?1", &vals![user_id])
        .await?;
    db.execute("DELETE FROM users WHERE id = ?1", &vals![user_id])
        .await?;
    Ok(())
}
