use std::time::Duration;

use axum::extract::{Path, State};
use axum::http::{header, HeaderValue, StatusCode};
use axum::response::{IntoResponse, Response};

use crate::error::{AppError, AppResult};
use crate::repo::{self, now_ms};
use crate::state::AppState;

const REDIRECT_TTL: Duration = Duration::from_secs(300);

pub async fn add_headers(mut res: Response) -> Response {
    let h = res.headers_mut();
    h.insert("x-robots-tag", HeaderValue::from_static("noindex"));
    h.insert(
        header::REFERRER_POLICY,
        HeaderValue::from_static("no-referrer"),
    );
    res
}

/// Handles `/s/{slug}` and `/s/{slug}.{ext}` (GET, and HEAD via axum).
pub async fn redirect(State(st): State<AppState>, Path(name): Path<String>) -> AppResult<Response> {
    let slug = name.split('.').next().unwrap_or("");
    if slug.is_empty() || slug.len() > 32 || !slug.chars().all(|c| c.is_ascii_alphanumeric()) {
        return Err(AppError::NotFound);
    }
    let (key, ct, expires_at) = repo::find_share(&st.db, slug)
        .await?
        .ok_or(AppError::NotFound)?;
    if expires_at < now_ms() {
        return Err(AppError::Gone);
    }
    let url = st
        .store
        .presign_get(&key, REDIRECT_TTL, &ct)
        .await
        .map_err(|e| AppError::Storage(e.0))?;
    let loc = HeaderValue::from_str(&url).map_err(|e| AppError::Internal(e.to_string()))?;
    Ok((
        StatusCode::FOUND,
        [
            (header::LOCATION, loc),
            (
                header::CACHE_CONTROL,
                HeaderValue::from_static("private, max-age=60"),
            ),
        ],
    )
        .into_response())
}
