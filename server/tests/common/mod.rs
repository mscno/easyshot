//! PostgreSQL test databases: one throwaway schema per test inside `TEST_DATABASE_URL`
//! (default: the local `easyshot_test` on port 5433), migrated as the owner. Tests get an
//! owner handle for setup and inspection (a superuser bypasses RLS) and an app-role handle
//! plus URL for the code under test (`easyshot_app`, NOBYPASSRLS, search_path = schema).

#![allow(dead_code)]

use std::str::FromStr;

use easyshot_server::config::Config;
use easyshot_server::db::{self, Db};
use sqlx::postgres::{PgConnectOptions, PgPoolOptions};
use sqlx::{ConnectOptions, Connection, Executor, PgConnection};
use tokio::sync::OnceCell;

pub const DEFAULT_TEST_URL: &str =
    "postgres://postgres:postgres@localhost:5433/easyshot_test?sslmode=disable";
pub const APP_ROLE: &str = "easyshot_app";

pub fn test_url() -> String {
    std::env::var("TEST_DATABASE_URL")
        .ok()
        .filter(|u| !u.is_empty())
        .unwrap_or_else(|| DEFAULT_TEST_URL.into())
}

/// Create the test database and the cluster-wide app role once per process.
async fn prepare() {
    static READY: OnceCell<()> = OnceCell::const_new();
    READY
        .get_or_init(|| async {
            let url = test_url();
            let opts = PgConnectOptions::from_str(&url).expect("TEST_DATABASE_URL");
            let name = opts.get_database().unwrap_or("easyshot_test").to_string();
            let mut admin = opts
                .clone()
                .database("postgres")
                .connect()
                .await
                .expect("connect to the test cluster (is Postgres on :5433 running?)");
            let exists: Option<i32> =
                sqlx::query_scalar("SELECT 1 FROM pg_database WHERE datname = $1")
                    .bind(&name)
                    .fetch_optional(&mut admin)
                    .await
                    .unwrap();
            if exists.is_none() {
                let _ = admin.execute(format!("CREATE DATABASE {name}").as_str()).await;
            }
            // Same statement as migration 0004; created here once so parallel per-test
            // migrations never race on the cluster-wide role.
            let _ = admin
                .execute(
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
    /// App-role URL (with search_path) for components that open their own pool (Toasty).
    pub app_url: String,
    pub schema: String,
}

impl TestDb {
    /// Server config pointing at the app role in this schema.
    pub fn config(&self) -> Config {
        Config::for_tests(&self.app_url)
    }

    /// Drop the schema.
    pub async fn finish(self) {
        self.app.pool().close().await;
        let _ = self
            .owner
            .pool()
            .execute(format!("DROP SCHEMA {} CASCADE", self.schema).as_str())
            .await;
        self.owner.pool().close().await;
    }
}

pub async fn database() -> TestDb {
    prepare().await;
    let url = test_url();
    let schema = format!("t_{}", uuid::Uuid::new_v4().simple());
    let opts = PgConnectOptions::from_str(&url).unwrap();
    {
        let mut conn = PgConnection::connect_with(&opts).await.unwrap();
        conn.execute(format!("CREATE SCHEMA {schema}").as_str())
            .await
            .unwrap();
        conn.execute(format!("SET search_path TO {schema}").as_str())
            .await
            .unwrap();
        db::migrate_conn(&mut conn).await.expect("migrations");
        conn.close().await.unwrap();
    }
    let owner = PgPoolOptions::new()
        .max_connections(3)
        .connect_with(opts.clone().options([("search_path", schema.as_str())]))
        .await
        .unwrap();
    let app_opts = opts
        .clone()
        .username(APP_ROLE)
        .password(APP_ROLE)
        .options([("search_path", schema.as_str())]);
    let app = PgPoolOptions::new()
        .max_connections(5)
        .connect_with(app_opts)
        .await
        .unwrap();
    let host = opts.get_host().to_string();
    let port = opts.get_port();
    let dbname = opts.get_database().unwrap_or("easyshot_test");
    let app_url = format!(
        "postgres://{APP_ROLE}:{APP_ROLE}@{host}:{port}/{dbname}?sslmode=disable&options=-csearch_path%3D{schema}"
    );
    TestDb {
        owner: Db::from_pool(owner),
        app: Db::from_pool(app),
        app_url,
        schema,
    }
}
