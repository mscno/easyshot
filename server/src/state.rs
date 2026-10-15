use std::sync::Arc;

use crate::config::Config;
use crate::db::Db;
use crate::mailer::{DisabledMailer, LettermintMailer, Mailer};
use crate::storage::{ObjectStore, S3Store};

#[derive(Clone)]
pub struct AppState {
    pub db: Db,
    pub store: Arc<dyn ObjectStore>,
    pub config: Arc<Config>,
    pub mailer: Arc<dyn Mailer>,
}

impl AppState {
    pub fn new(db: Db, store: Arc<dyn ObjectStore>, config: Config) -> Self {
        Self {
            db,
            store,
            config: Arc::new(config),
            mailer: Arc::new(DisabledMailer),
        }
    }

    pub fn with_mailer(mut self, mailer: Arc<dyn Mailer>) -> Self {
        self.mailer = mailer;
        self
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
