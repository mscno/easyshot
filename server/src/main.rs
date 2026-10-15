use shotglass_server::config::Config;
use shotglass_server::{router, AppState};
use tracing_subscriber::EnvFilter;

type BoxErr = Box<dyn std::error::Error + Send + Sync>;

#[tokio::main]
async fn main() -> Result<(), BoxErr> {
    tracing_subscriber::fmt()
        .json()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")),
        )
        .without_time()
        .init();

    let config = Config::from_env().map_err(|e| format!("config error: {e}"))?;
    let run_migrations = config.run_migrations;
    let bind = config.bind_addr.clone();
    let state = AppState::from_config(config).await?;

    if run_migrations {
        tracing::info!(backend = state.db.backend(), "running migrations");
        state.db.migrate().await?;
    }

    let app = router(state);

    #[cfg(feature = "lambda")]
    {
        let _ = bind;
        lambda_http::run(app).await
    }

    #[cfg(not(feature = "lambda"))]
    {
        let listener = tokio::net::TcpListener::bind(&bind).await?;
        tracing::info!(addr = %bind, "listening");
        axum::serve(listener, app)
            .with_graceful_shutdown(shutdown_signal())
            .await?;
        Ok(())
    }
}

#[cfg(not(feature = "lambda"))]
async fn shutdown_signal() {
    let ctrl_c = async {
        let _ = tokio::signal::ctrl_c().await;
    };
    #[cfg(unix)]
    let term = async {
        if let Ok(mut s) = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
        {
            s.recv().await;
        }
    };
    #[cfg(not(unix))]
    let term = std::future::pending::<()>();
    tokio::select! { _ = ctrl_c => {}, _ = term => {} }
    tracing::info!("shutting down");
}
