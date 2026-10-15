//! Toasty for the video domain, over its PostgreSQL driver.
//!
//! The Toasty pool connects as the same app role as the sqlx pool (`DATABASE_URL`), so
//! row-level security applies. Every unit of work runs in a Toasty transaction that first
//! installs the RLS [`Context`] with `set_config(..., true)` through `toasty::sql` on the
//! transaction's own connection ([`begin`]); outside such a transaction owner-scoped tables
//! read as empty. Schema is owned by `migrations/*.sql`; Toasty never pushes or migrates.

use toasty::Transaction;
use toasty_driver_postgresql::PostgreSQL;

use crate::config::Config;
use crate::db::Context;
use crate::error::{AppError, AppResult};

/// Build the Toasty handle (opens one connection to validate the URL).
pub async fn connect(cfg: &Config) -> toasty::Result<toasty::Db> {
    toasty::Db::builder()
        .models(crate::video::model::models())
        .max_pool_size(cfg.db_max_connections as usize)
        .build(PostgreSQL::new(cfg.database_url.trim())?)
        .await
}

/// Start a transaction with `ctx` applied. Commit it explicitly; dropping rolls back.
pub async fn begin<'a>(db: &'a mut toasty::Db, ctx: &Context) -> AppResult<Transaction<'a>> {
    let mut tx = db.transaction().await.map_err(orm_err)?;
    let mut q = toasty::sql::query(Context::SQL);
    for p in ctx.params() {
        q = q.bind(p);
    }
    q.exec(&mut tx).await.map_err(orm_err)?;
    Ok(tx)
}

pub fn orm_err(e: toasty::Error) -> AppError {
    if is_unique_violation(&e) {
        return AppError::Db(crate::db::DbError::UniqueViolation);
    }
    AppError::Internal(format!("orm: {e}"))
}

/// True when a Toasty error came from a unique-constraint violation (SQLSTATE 23505).
pub fn is_unique_violation(e: &toasty::Error) -> bool {
    let s = format!("{e:?}");
    s.contains("23505") || s.contains("duplicate key value")
}
