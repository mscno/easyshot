use std::time::{Duration, Instant};

use axum::Json;
use axum::extract::State;
use axum::http::HeaderMap;
use serde_json::{Value, json};
use subtle::ConstantTimeEq;
use uuid::Uuid;

use crate::error::{AppError, AppResult};
use crate::repo;
use crate::state::AppState;

const BATCH: i64 = 500;
const USER_BATCH: i64 = 100;
const TIME_BUDGET: Duration = Duration::from_secs(25);
const HOUR_MS: i64 = 3_600_000;
const DAY_MS: i64 = 86_400_000;

#[derive(Clone, Copy)]
enum Phase {
    Expired,
    StalePending,
}

/// Selects a batch, deletes its objects, then deletes the rows by id. Not transactional on
/// purpose: every step is idempotent, so overlapping runs and retries are safe. If the store
/// fails the rows are kept for the next run.
async fn purge_batch(st: &AppState, phase: Phase, now: i64) -> AppResult<usize> {
    let rows = match phase {
        Phase::Expired => repo::expired_screenshots(&st.db, now, BATCH).await?,
        Phase::StalePending => {
            repo::stale_pending_screenshots(&st.db, now - HOUR_MS, BATCH).await?
        }
    };
    delete_rows_and_objects(st, &rows).await?;
    Ok(rows.len())
}

async fn delete_rows_and_objects(st: &AppState, rows: &repo::KeyedIds) -> AppResult<()> {
    if rows.is_empty() {
        return Ok(());
    }
    let keys: Vec<String> = rows.iter().map(|r| r.1.clone()).collect();
    st.store
        .delete_many(&keys)
        .await
        .map_err(|e| AppError::Storage(e.0))?;
    let ids: Vec<Uuid> = rows.iter().map(|r| r.0).collect();
    repo::delete_screenshots_by_ids(&st.db, &ids).await?;
    Ok(())
}

/// Purge users not seen since `cutoff`: objects first, then screenshot rows, sessions, API
/// tokens and finally the user. Returns `(purged, more)`.
async fn purge_inactive_users(
    st: &AppState,
    cutoff: i64,
    deadline: Instant,
) -> AppResult<(usize, bool)> {
    let mut purged = 0;
    loop {
        if Instant::now() >= deadline {
            return Ok((purged, true));
        }
        let users = repo::inactive_users(&st.db, cutoff, USER_BATCH).await?;
        for &user in &users {
            loop {
                if Instant::now() >= deadline {
                    return Ok((purged, true));
                }
                let rows = repo::user_screenshots(&st.db, user, BATCH).await?;
                if rows.is_empty() {
                    break;
                }
                delete_rows_and_objects(st, &rows).await?;
            }
            crate::video::service::purge_user(st, user).await?;
            repo::delete_user_records(&st.db, user).await?;
            purged += 1;
        }
        if (users.len() as i64) < USER_BATCH {
            return Ok((purged, false));
        }
    }
}

pub async fn expire(State(st): State<AppState>, headers: HeaderMap) -> AppResult<Json<Value>> {
    let Some(secret) = st.config.cron_secret.as_deref() else {
        return Err(AppError::NotFound);
    };
    let provided = headers
        .get(axum::http::header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .unwrap_or("");
    if !bool::from(provided.as_bytes().ct_eq(secret.as_bytes())) {
        return Err(AppError::Unauthorized);
    }

    let deadline = Instant::now() + TIME_BUDGET;
    let now = repo::now_ms();
    let mut more = false;
    let mut expired = 0usize;
    let mut purged_pending = 0usize;

    'phases: for (phase, counter) in [
        (Phase::Expired, &mut expired),
        (Phase::StalePending, &mut purged_pending),
    ] {
        loop {
            if Instant::now() >= deadline {
                more = true;
                break 'phases;
            }
            let n = purge_batch(&st, phase, now).await?;
            *counter += n;
            if (n as i64) < BATCH {
                break;
            }
        }
    }

    let (mut expired_videos, mut aborted_uploads) = (0usize, 0usize);
    if !more {
        loop {
            if Instant::now() >= deadline {
                more = true;
                break;
            }
            let (e, a) = crate::video::service::purge_batch(&st, now, BATCH as usize).await?;
            expired_videos += e;
            aborted_uploads += a;
            if ((e + a) as i64) < BATCH {
                break;
            }
        }
    }

    let mut purged_users = 0;
    let days = st.config.inactive_user_days;
    if days > 0 && !more {
        let (n, m) = purge_inactive_users(&st, now - days * DAY_MS, deadline).await?;
        purged_users = n;
        more |= m;
    }

    let purged_sessions = repo::delete_expired_sessions(&st.db, now).await?;
    repo::delete_old_login_attempts(&st.db, now - DAY_MS).await?;
    repo::delete_old_codes(&st.db, now - DAY_MS).await?;

    tracing::info!(
        expired,
        purged_pending,
        purged_users,
        purged_sessions,
        expired_videos,
        aborted_uploads,
        more,
        "expire job finished"
    );
    Ok(Json(json!({
        "expired": expired,
        "purged_pending": purged_pending,
        "purged_sessions": purged_sessions,
        "purged_users": purged_users,
        "expired_videos": expired_videos,
        "aborted_uploads": aborted_uploads,
        "more": more,
    })))
}
