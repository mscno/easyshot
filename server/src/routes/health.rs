use axum::Json;
use axum::extract::{Query, State};
use serde::Deserialize;
use serde_json::{Value, json};

use crate::error::AppResult;
use crate::state::AppState;

#[derive(Deserialize)]
pub struct HealthQuery {
    db: Option<String>,
}

pub async fn healthz(
    State(st): State<AppState>,
    Query(q): Query<HealthQuery>,
) -> AppResult<Json<Value>> {
    if matches!(q.db.as_deref(), Some("1") | Some("true")) {
        st.db.query("SELECT 1", &[]).await?;
    }
    Ok(Json(json!({"ok": true})))
}
