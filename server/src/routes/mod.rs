use axum::extract::{DefaultBodyLimit, FromRequest, Request};
use axum::routing::{get, post};
use axum::{Json, Router};
use serde::de::DeserializeOwned;
use tower_http::trace::TraceLayer;

use crate::error::AppError;
use crate::state::AppState;

pub mod auth;
pub mod codes;
pub mod health;
pub mod internal;
pub mod screenshots;
pub mod share;
pub mod tokens;
pub mod videos;

pub const JSON_BODY_LIMIT: usize = 64 * 1024;

/// JSON extractor whose rejections use the standard error envelope.
pub struct ApiJson<T>(pub T);

impl<T, S> FromRequest<S> for ApiJson<T>
where
    T: DeserializeOwned,
    S: Send + Sync,
{
    type Rejection = AppError;

    async fn from_request(req: Request, state: &S) -> Result<Self, AppError> {
        match Json::<T>::from_request(req, state).await {
            Ok(Json(v)) => Ok(ApiJson(v)),
            Err(rej) => {
                if rej.status() == axum::http::StatusCode::PAYLOAD_TOO_LARGE {
                    Err(AppError::TooLarge)
                } else {
                    Err(AppError::Invalid("invalid JSON body".into()))
                }
            }
        }
    }
}

pub fn router(state: AppState) -> Router {
    let v1 = Router::new()
        .route("/auth/register", post(auth::register))
        .route("/auth/login", post(auth::login))
        .route("/auth/logout", post(auth::logout))
        .route("/auth/verify-email/send", post(codes::verify_send))
        .route("/auth/verify-email/confirm", post(codes::verify_confirm))
        .route("/auth/password/forgot", post(codes::password_forgot))
        .route("/auth/password/reset", post(codes::password_reset))
        .route("/auth/otp/request", post(codes::otp_request))
        .route("/auth/otp/verify", post(codes::otp_verify))
        .route("/me", get(auth::me))
        .route("/tokens", post(tokens::create).get(tokens::list))
        .route("/tokens/{id}", axum::routing::delete(tokens::revoke))
        .route(
            "/screenshots",
            post(screenshots::create).get(screenshots::list),
        )
        .route(
            "/screenshots/{id}",
            axum::routing::delete(screenshots::delete),
        )
        .route("/screenshots/{id}/complete", post(screenshots::complete))
        .route("/videos", post(videos::create).get(videos::list))
        .route(
            "/videos/{id}",
            get(videos::get)
                .patch(videos::update)
                .delete(videos::delete),
        )
        .route("/videos/{id}/parts", post(videos::parts))
        .route("/videos/{id}/progress", post(videos::progress))
        .route("/videos/{id}/complete", post(videos::complete))
        .route("/videos/{id}/thumbnail", post(videos::thumbnail))
        .route("/videos/{id}/transcript", post(videos::transcript))
        .route("/internal/expire", post(internal::expire))
        .layer(DefaultBodyLimit::max(JSON_BODY_LIMIT));

    Router::new()
        .route("/healthz", get(health::healthz))
        .route(
            "/s/{slug}",
            get(share::redirect).layer(axum::middleware::map_response(share::add_headers)),
        )
        .nest("/v1", v1)
        .fallback(|| async { AppError::NotFound })
        .layer(TraceLayer::new_for_http())
        .with_state(state)
}
