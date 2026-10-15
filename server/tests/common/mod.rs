//! Backends for the video/web suites: a fresh libSQL file always, plus a throwaway Postgres
//! schema when `DATABASE_URL` is a postgres URL. Call `finish` to remove the temp file or schema.

#![allow(dead_code)]

use std::path::PathBuf;

use shotglass_server::config::Config;
use shotglass_server::db::Db;
use sqlx::postgres::PgPoolOptions;
use sqlx::{Executor, PgPool};

pub enum Cleanup {
    File(PathBuf),
    Pg { admin: PgPool, schema: String },
}

pub struct TestDb {
    pub db: Db,
    pub url: String,
    cleanup: Option<Cleanup>,
}

impl TestDb {
    /// Remove the temp file or drop the schema.
    pub async fn finish(mut self) {
        match self.cleanup.take() {
            Some(Cleanup::File(p)) => {
                let _ = std::fs::remove_file(&p);
            }
            Some(Cleanup::Pg { admin, schema }) => {
                let _ = admin
                    .execute(format!("DROP SCHEMA {schema} CASCADE").as_str())
                    .await;
            }
            None => {}
        }
    }
}

pub async fn libsql() -> TestDb {
    let path = std::env::temp_dir().join(format!("shotglass-web-{}.db", uuid::Uuid::new_v4()));
    let url = format!("file:{}", path.display());
    let db = Db::connect(&Config::for_tests(&url)).unwrap();
    db.migrate().await.unwrap();
    TestDb {
        db,
        url,
        cleanup: Some(Cleanup::File(path)),
    }
}

pub async fn postgres() -> Option<TestDb> {
    let url = std::env::var("DATABASE_URL").ok()?;
    if !(url.starts_with("postgres://") || url.starts_with("postgresql://")) {
        return None;
    }
    let schema = format!("t_{}", uuid::Uuid::new_v4().simple());
    let admin = PgPoolOptions::new()
        .max_connections(1)
        .connect(&url)
        .await
        .expect("connect");
    admin
        .execute(format!("CREATE SCHEMA {schema}").as_str())
        .await
        .unwrap();
    let s = schema.clone();
    let pool = PgPoolOptions::new()
        .max_connections(5)
        .after_connect(move |conn, _| {
            let s = s.clone();
            Box::pin(async move {
                conn.execute(format!("SET search_path TO {s}").as_str())
                    .await?;
                Ok(())
            })
        })
        .connect(&url)
        .await
        .unwrap();
    let db = Db::Pg(pool);
    db.migrate().await.unwrap();
    Some(TestDb {
        db,
        url,
        cleanup: Some(Cleanup::Pg { admin, schema }),
    })
}

/// libSQL always; Postgres too when configured.
pub async fn databases() -> Vec<TestDb> {
    let mut v = vec![libsql().await];
    match postgres().await {
        Some(pg) => v.push(pg),
        None => eprintln!("DATABASE_URL is not postgres; skipping postgres run"),
    }
    v
}
