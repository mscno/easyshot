//! Single `tokio-postgres` connections for the two jobs Toasty's pool cannot do: running
//! multi-statement migration files as the owner (`batch_execute`, simple protocol) and
//! holding a `LISTEN` session for live updates. Never a pool; everything else goes through
//! Toasty ([`crate::db::Db`]).
//!
//! TLS follows the URL's `sslmode`: `disable` connects in plain text; `prefer`/`require`
//! use rustls with the platform verifier, like the Toasty driver.

use std::str::FromStr;
use std::sync::Arc;

use tokio_postgres::config::SslMode;
use tokio_postgres::{AsyncMessage, Client, Config, NoTls, Notification};

use crate::db::{DbError, DbResult};

fn tls() -> DbResult<tokio_postgres_rustls::MakeRustlsConnect> {
    use rustls::crypto::CryptoProvider;
    let provider = match CryptoProvider::get_default() {
        Some(p) => p.clone(),
        None => {
            let _ = rustls::crypto::ring::default_provider().install_default();
            CryptoProvider::get_default().expect("installed").clone()
        }
    };
    let verifier = rustls_platform_verifier::Verifier::new(provider.clone())
        .map_err(|e| DbError::Other(format!("tls: {e}")))?;
    let config = rustls::ClientConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()
        .map_err(|e| DbError::Other(format!("tls: {e}")))?
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(verifier))
        .with_no_client_auth();
    Ok(tokio_postgres_rustls::MakeRustlsConnect::new(config))
}

fn config(url: &str) -> DbResult<Config> {
    Config::from_str(&libpq_tls_compat(url.trim()))
        .map_err(|e| DbError::Other(format!("database url: {e}")))
}

/// The user name in a connection URL, if any.
pub fn url_user(url: &str) -> Option<String> {
    config(url).ok()?.get_user().map(str::to_string)
}

/// tokio-postgres only parses `sslmode=disable|prefer|require` and rejects libpq's
/// certificate parameters. Our TLS config always checks the chain and host name with the
/// platform verifier, so `verify-ca`/`verify-full` become `require` and `sslrootcert`,
/// `sslcert` and `sslkey` are dropped. The same URL then works for Toasty, which needs
/// `sslmode=verify-full&sslrootcert=system` for managed providers such as PlanetScale.
fn libpq_tls_compat(url: &str) -> String {
    let Some((base, query)) = url.split_once('?') else {
        return url.to_string();
    };
    let kept: Vec<String> = query
        .split('&')
        .filter(|kv| !kv.is_empty())
        .filter_map(|kv| match kv.split_once('=') {
            Some(("sslrootcert" | "sslcert" | "sslkey", _)) => None,
            Some(("sslmode", "verify-ca" | "verify-full")) => Some("sslmode=require".to_string()),
            _ => Some(kv.to_string()),
        })
        .collect();
    if kept.is_empty() {
        base.to_string()
    } else {
        format!("{base}?{}", kept.join("&"))
    }
}

/// Open one connection. Notifications (and notices) go to `on_message`, if given; the
/// connection task ends when the client is dropped or the server closes the session.
pub async fn connect(
    url: &str,
    on_message: Option<tokio::sync::mpsc::UnboundedSender<Notification>>,
) -> DbResult<Client> {
    let cfg = config(url)?;
    macro_rules! drive {
        ($conn:expr) => {{
            let mut conn = $conn;
            tokio::spawn(async move {
                let mut stream =
                    futures_util::stream::poll_fn(move |cx| conn.poll_message(cx));
                use futures_util::StreamExt;
                while let Some(msg) = stream.next().await {
                    match msg {
                        Ok(AsyncMessage::Notification(n)) => {
                            if let Some(tx) = &on_message {
                                let _ = tx.send(n);
                            }
                        }
                        Ok(_) => {}
                        Err(e) => {
                            tracing::warn!(error = %e, "postgres connection closed");
                            break;
                        }
                    }
                }
            });
        }};
    }
    let pg = |e: tokio_postgres::Error| DbError::Other(e.to_string());
    if cfg.get_ssl_mode() == SslMode::Disable {
        let (client, conn) = cfg.connect(NoTls).await.map_err(pg)?;
        drive!(conn);
        Ok(client)
    } else {
        let (client, conn) = cfg.connect(tls()?).await.map_err(pg)?;
        drive!(conn);
        Ok(client)
    }
}

pub fn pg_err(e: tokio_postgres::Error) -> DbError {
    if e.code() == Some(&tokio_postgres::error::SqlState::UNIQUE_VIOLATION) {
        return DbError::UniqueViolation;
    }
    DbError::Other(match e.as_db_error() {
        Some(d) => d.message().to_string(),
        None => e.to_string(),
    })
}

#[cfg(test)]
mod tls_url_tests {
    use super::*;

    #[test]
    fn verify_modes_map_to_require_and_cert_params_drop() {
        assert_eq!(
            libpq_tls_compat("postgresql://u:p@h:5432/db?sslmode=verify-full&sslrootcert=system"),
            "postgresql://u:p@h:5432/db?sslmode=require"
        );
        assert_eq!(
            libpq_tls_compat("postgres://u@h/db?sslmode=verify-ca&application_name=x"),
            "postgres://u@h/db?sslmode=require&application_name=x"
        );
        assert_eq!(
            libpq_tls_compat("postgres://u@h/db?sslmode=disable"),
            "postgres://u@h/db?sslmode=disable"
        );
        assert_eq!(
            libpq_tls_compat("postgres://u@h/db?sslrootcert=/x.pem"),
            "postgres://u@h/db"
        );
        assert_eq!(libpq_tls_compat("postgres://u@h/db"), "postgres://u@h/db");
        let cfg =
            config("postgresql://u:p@h:5432/db?sslmode=verify-full&sslrootcert=system").unwrap();
        assert_eq!(cfg.get_ssl_mode(), SslMode::Require);
    }
}
