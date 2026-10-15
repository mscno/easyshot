//! PostgreSQL test databases: one throwaway schema per test inside `TEST_DATABASE_URL`
//! (default: the local `easyshot_test` on port 5432), migrated as the owner. Tests get an
//! owner handle for setup and inspection (a superuser bypasses RLS) and an app-role handle
//! plus URL for the code under test (`easyshot_app`, NOBYPASSRLS, search_path = schema).

#![allow(dead_code)]

use std::str::FromStr;

use easyshot_server::config::Config;
use easyshot_server::db::{self, Db};
use easyshot_server::pg;
use tokio::sync::OnceCell;

pub const DEFAULT_TEST_URL: &str =
    "postgres://postgres:postgres@localhost:5432/easyshot_test?sslmode=disable";
pub const APP_ROLE: &str = "easyshot_app";

pub fn test_url() -> String {
    std::env::var("TEST_DATABASE_URL")
        .ok()
        .filter(|u| !u.is_empty())
        .unwrap_or_else(|| DEFAULT_TEST_URL.into())
}

/// `url` with its database name replaced and extra query parameters appended.
fn with(url: &str, user: Option<&str>, db: Option<&str>, extra: &str) -> String {
    let cfg = tokio_postgres::Config::from_str(url).expect("TEST_DATABASE_URL");
    let host = match cfg.get_hosts().first() {
        Some(tokio_postgres::config::Host::Tcp(h)) => h.clone(),
        _ => "localhost".into(),
    };
    let port = cfg.get_ports().first().copied().unwrap_or(5432);
    let (user, pass) = match user {
        Some(u) => (u.to_string(), u.to_string()),
        None => (
            cfg.get_user().unwrap_or("postgres").to_string(),
            cfg.get_password()
                .map(|p| String::from_utf8_lossy(p).into_owned())
                .unwrap_or_default(),
        ),
    };
    let name = db.unwrap_or(cfg.get_dbname().unwrap_or("easyshot_test"));
    format!("postgres://{user}:{pass}@{host}:{port}/{name}?sslmode=disable{extra}")
}

pub fn test_db_name() -> String {
    tokio_postgres::Config::from_str(&test_url())
        .ok()
        .and_then(|c| c.get_dbname().map(str::to_string))
        .unwrap_or_else(|| "easyshot_test".into())
}

/// Create the test database and the cluster-wide app role once per process.
async fn prepare() {
    static READY: OnceCell<()> = OnceCell::const_new();
    READY
        .get_or_init(|| async {
            let url = test_url();
            let name = test_db_name();
            let admin = pg::connect(&with(&url, None, Some("postgres"), ""), None)
                .await
                .expect("connect to the test cluster (is Postgres on :5432 running?)");
            let exists = admin
                .query_opt("SELECT 1 FROM pg_database WHERE datname = $1", &[&name])
                .await
                .unwrap();
            if exists.is_none() {
                let _ = admin.batch_execute(&format!("CREATE DATABASE {name}")).await;
            }
            // Same statement as migration 0004; created here once so parallel per-test
            // migrations never race on the cluster-wide role.
            let _ = admin
                .batch_execute(
                    "DO $$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'easyshot_app') THEN \
                     CREATE ROLE easyshot_app LOGIN NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE NOINHERIT \
                     PASSWORD 'easyshot_app'; END IF; END $$",
                )
                .await;
        })
        .await;
}

pub struct TestDb {
    /// Owner/superuser handle in the test schema: setup and inspection, bypasses RLS.
    pub owner: Db,
    /// App-role handle in the test schema: what the server uses; RLS applies.
    pub app: Db,
    /// App-role URL (with search_path) for components that open their own pool.
    pub app_url: String,
    /// Owner URL (with search_path), e.g. for a LISTEN connection.
    pub owner_url: String,
    pub schema: String,
}

impl TestDb {
    /// Server config pointing at the app role in this schema.
    pub fn config(&self) -> Config {
        Config::for_tests(&self.app_url)
    }

    /// Drop the schema.
    pub async fn finish(self) {
        let _ = self
            .owner
            .execute(&format!("DROP SCHEMA {} CASCADE", self.schema), &[])
            .await;
    }
}

pub async fn database() -> TestDb {
    prepare().await;
    let url = test_url();
    let schema = format!("t_{}", uuid::Uuid::new_v4().simple());
    let search_path = format!("&options=-csearch_path%3D{schema}");
    {
        let mut conn = pg::connect(&with(&url, None, None, ""), None)
            .await
            .unwrap();
        conn.batch_execute(&format!(
            "CREATE SCHEMA {schema}; SET search_path TO {schema}"
        ))
        .await
        .unwrap();
        db::migrate_conn(&mut conn).await.expect("migrations");
    }
    let owner_url = with(&url, None, None, &search_path);
    let app_url = with(&url, Some(APP_ROLE), None, &search_path);
    let owner = Db::connect_url(&owner_url, 3).await.unwrap();
    let app = Db::connect_url(&app_url, 5).await.unwrap();
    TestDb {
        owner,
        app,
        app_url,
        owner_url,
        schema,
    }
}
