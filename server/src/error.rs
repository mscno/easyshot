use axum::Json;
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use serde_json::json;

#[derive(Debug, thiserror::Error)]
pub enum AppError {
    #[error("invalid or missing credentials")]
    Unauthorized,
    #[error("invalid email or password")]
    InvalidCredentials,
    #[error("too many failed attempts, try again later")]
    RateLimited,
    #[error("email already registered")]
    EmailTaken,
    #[error("signups are disabled")]
    SignupsDisabled,
    #[error("email is not configured on this server")]
    EmailUnavailable,
    #[error("confirm your email address to continue")]
    EmailNotVerified,
    #[error("invalid or expired code")]
    InvalidCode,
    #[error("{0}")]
    Invalid(String),
    #[error("not found")]
    NotFound,
    #[error("this screenshot has expired")]
    Gone,
    #[error("file too large")]
    TooLarge,
    #[error("unsupported content type")]
    UnsupportedType,
    #[error("object has not been uploaded")]
    NotUploaded,
    #[error("uploaded size does not match declared size")]
    SizeMismatch,
    #[error("finish or delete an unfinished upload first")]
    TooManyPendingUploads,
    #[error("storage error: {0}")]
    Storage(String),
    #[error("database error: {0}")]
    Db(#[from] crate::db::DbError),
    #[error("internal error: {0}")]
    Internal(String),
}

impl AppError {
    fn parts(&self) -> (StatusCode, &'static str) {
        use AppError::*;
        match self {
            Unauthorized => (StatusCode::UNAUTHORIZED, "UNAUTHORIZED"),
            InvalidCredentials => (StatusCode::UNAUTHORIZED, "INVALID_CREDENTIALS"),
            RateLimited => (StatusCode::TOO_MANY_REQUESTS, "RATE_LIMITED"),
            EmailTaken => (StatusCode::CONFLICT, "EMAIL_TAKEN"),
            SignupsDisabled => (StatusCode::FORBIDDEN, "SIGNUPS_DISABLED"),
            EmailUnavailable => (StatusCode::SERVICE_UNAVAILABLE, "EMAIL_UNAVAILABLE"),
            EmailNotVerified => (StatusCode::FORBIDDEN, "EMAIL_NOT_VERIFIED"),
            InvalidCode => (StatusCode::UNAUTHORIZED, "INVALID_CODE"),
            Invalid(_) => (StatusCode::BAD_REQUEST, "INVALID_REQUEST"),
            NotFound => (StatusCode::NOT_FOUND, "NOT_FOUND"),
            Gone => (StatusCode::GONE, "GONE"),
            TooLarge => (StatusCode::PAYLOAD_TOO_LARGE, "TOO_LARGE"),
            UnsupportedType => (StatusCode::UNSUPPORTED_MEDIA_TYPE, "UNSUPPORTED_TYPE"),
            NotUploaded => (StatusCode::CONFLICT, "NOT_UPLOADED"),
            SizeMismatch => (StatusCode::UNPROCESSABLE_ENTITY, "SIZE_MISMATCH"),
            TooManyPendingUploads => (StatusCode::TOO_MANY_REQUESTS, "TOO_MANY_PENDING_UPLOADS"),
            Storage(_) => (StatusCode::BAD_GATEWAY, "STORAGE_ERROR"),
            Db(_) | Internal(_) => (StatusCode::INTERNAL_SERVER_ERROR, "INTERNAL"),
        }
    }
}

impl IntoResponse for AppError {
    fn into_response(self) -> Response {
        let (status, code) = self.parts();
        let message = match &self {
            AppError::Db(_) | AppError::Internal(_) => {
                tracing::error!(error = %self, "internal error");
                "internal server error".to_string()
            }
            AppError::Storage(_) => {
                tracing::error!(error = %self, "storage error");
                "object storage error".to_string()
            }
            other => other.to_string(),
        };
        (
            status,
            Json(json!({"error": {"code": code, "message": message}})),
        )
            .into_response()
    }
}

pub type AppResult<T> = Result<T, AppError>;
