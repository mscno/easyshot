//! `easyshot-server [serve]` runs the web app and API; `migrate up|status|reset --yes`,
//! `seed` and `db bootstrap|verify` (see `prod`) manage the database as the owner role
//! (`--database-url` or `MIGRATION_DATABASE_URL`).

use easyshot_server::config::Config;
use easyshot_server::{AppState, db};
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

    let args: Vec<String> = std::env::args().skip(1).collect();
    let mut words: Vec<&str> = Vec::new();
    let mut it = args.iter();
    while let Some(a) = it.next() {
        match a.as_str() {
            "--database-url" => {
                it.next();
            }
            a if a.starts_with("--") => {}
            a => words.push(a),
        }
    }
    let flag = |name: &str| {
        args.iter()
            .position(|a| a == name)
            .and_then(|i| args.get(i + 1).cloned())
    };
    let owner_url = || -> Result<String, BoxErr> {
        flag("--database-url")
            .or_else(|| std::env::var("MIGRATION_DATABASE_URL").ok())
            .filter(|u| !u.is_empty())
            .ok_or_else(|| "pass --database-url or set MIGRATION_DATABASE_URL (owner role)".into())
    };
    match words.as_slice() {
        [] | ["serve"] => serve().await,
        ["migrate", "up"] | ["migrate"] => {
            for name in db::migrate(&owner_url()?).await? {
                println!("applied {name}");
            }
            Ok(())
        }
        ["migrate", "status"] => {
            for (name, applied) in db::status(&owner_url()?).await? {
                println!("{} {name}", if applied { "applied" } else { "pending" });
            }
            Ok(())
        }
        ["migrate", "reset"] if args.iter().any(|a| a == "--yes") => {
            for name in db::reset(&owner_url()?).await? {
                println!("applied {name}");
            }
            Ok(())
        }
        ["seed"] => {
            let url = owner_url()?;
            let summary = easyshot_server::seed::run(&url).await?;
            println!("{summary}");
            Ok(())
        }
        ["db", "bootstrap"] => {
            use easyshot_server::prod::AppLogin;
            let password = std::env::var("APP_DATABASE_PASSWORD").ok();
            let app_url = std::env::var("DATABASE_URL").ok();
            let login = match (&password, &app_url) {
                (Some(p), _) if !p.is_empty() => AppLogin::Password(p),
                (_, Some(u)) if !u.is_empty() => AppLogin::Provider { app_url: u },
                _ => return Err("set DATABASE_URL (a provider login such as `pscale role create`) or APP_DATABASE_PASSWORD".into()),
            };
            for line in easyshot_server::prod::bootstrap(&owner_url()?, login).await? {
                println!("{line}");
            }
            Ok(())
        }
        ["db", "verify"] => {
            let app_url = std::env::var("DATABASE_URL")
                .map_err(|_| "set DATABASE_URL (the app-role URL the server uses)")?;
            let checks = easyshot_server::prod::verify(&owner_url()?, &app_url).await?;
            for (what, ok) in &checks {
                println!("{} {what}", if *ok { "ok  " } else { "FAIL" });
            }
            if checks.iter().all(|(_, ok)| *ok) {
                Ok(())
            } else {
                Err("database verification failed".into())
            }
        }
        _ => Err(
            "usage: easyshot-server [serve] | migrate up|status|reset --yes | seed | db bootstrap|verify"
                .into(),
        ),
    }
}

async fn serve() -> Result<(), BoxErr> {
    let config = Config::from_env().map_err(|e| format!("config error: {e}"))?;
    if config.run_migrations {
        let url = config
            .migration_database_url
            .clone()
            .ok_or("RUN_MIGRATIONS needs MIGRATION_DATABASE_URL (owner role)")?;
        tracing::info!("running migrations");
        db::migrate(&url).await?;
    }
    let bind = config.bind_addr.clone();
    let state = AppState::from_config(config).await?;

    #[cfg(feature = "lambda")]
    {
        // Lambda serves the JSON API only; web pages need the container deploy.
        let _ = bind;
        lambda_http::run(easyshot_server::router(state)).await
    }

    #[cfg(not(feature = "lambda"))]
    {
        let listener = tokio::net::TcpListener::bind(&bind).await?;
        tracing::info!(addr = %bind, "listening");
        topcoat::serve(listener, easyshot_server::web::router(state)).await?;
        Ok(())
    }
}
