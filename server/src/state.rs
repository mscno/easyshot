use std::sync::Arc;

use rand::RngCore;
use sha2::{Digest, Sha256};
use tokio::sync::OnceCell;

use crate::config::Config;
use crate::db::Db;
use crate::error::{AppError, AppResult};
use crate::mailer::{DisabledMailer, LettermintMailer, Mailer};
use crate::storage::{ObjectStore, S3Store};
use crate::video::live::Hub;
use crate::video::limit::RateLimiter;

#[derive(Clone)]
pub struct AppState {
    pub db: Db,
    pub store: Arc<dyn ObjectStore>,
    pub config: Arc<Config>,
    pub mailer: Arc<dyn Mailer>,
    /// Toasty handle for the video models, built on first use over `db`.
    orm: Arc<OnceCell<toasty::Db>>,
    /// In-process fan-out of video updates to open watch pages.
    pub live: Arc<Hub>,
    pub limiter: Arc<RateLimiter>,
    /// 32-byte key for unlock cookies and viewer hashes (see `Config::web_secret`).
    pub secret: Arc<[u8; 32]>,
}

impl AppState {
    pub fn new(db: Db, store: Arc<dyn ObjectStore>, config: Config) -> Self {
        let secret = match &config.web_secret {
            Some(s) => Sha256::digest(s.as_bytes()).into(),
            None => {
                let mut k = [0u8; 32];
                rand::rngs::OsRng.fill_bytes(&mut k);
                k
            }
        };
        Self {
            db,
            store,
            config: Arc::new(config),
            mailer: Arc::new(DisabledMailer),
            orm: Arc::new(OnceCell::new()),
            live: Arc::new(Hub::default()),
            limiter: Arc::new(RateLimiter::default()),
            secret: Arc::new(secret),
        }
    }

    pub fn with_mailer(mut self, mailer: Arc<dyn Mailer>) -> Self {
        self.mailer = mailer;
        self
    }

    /// A Toasty executor for the video models (clones share the pool).
    pub async fn orm(&self) -> AppResult<toasty::Db> {
        self.orm
            .get_or_try_init(|| crate::orm::connect(&self.config))
            .await
            .cloned()
            .map_err(|e| AppError::Internal(format!("orm: {e}")))
    }

    /// Production wiring: lazy database handle + S3 store. No network I/O happens here.
    pub async fn from_config(
        config: Config,
    ) -> Result<Self, Box<dyn std::error::Error + Send + Sync>> {
        let db = Db::connect(&config)?;
        let store = S3Store::from_config(&config).await;
        let state = Self::new(db, Arc::new(store), config);
        let mailer: Option<Arc<dyn Mailer>> =
            LettermintMailer::from_config(&state.config).map(|m| Arc::new(m) as Arc<dyn Mailer>);
        Ok(match mailer {
            Some(m) => state.with_mailer(m),
            None => state,
        })
    }
}
