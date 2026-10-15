//! Toasty models for the video domain, on the same pool as the repository layer
//! ([`crate::db::Db::toasty`]).
//!
//! The pool connects as the app role (`DATABASE_URL`), so row-level security applies.
//! Every unit of work runs in a Toasty transaction that first installs the RLS
//! [`Context`] with `set_config(..., true)` on the transaction's own connection
//! ([`begin`]); outside such a transaction owner-scoped tables read as empty. Schema is
//! owned by `migrations/*.sql`; Toasty never pushes or migrates.

use toasty::Transaction;

use crate::db::Context;
use crate::error::{AppError, AppResult};

/// Start a transaction with `ctx` applied. Commit it explicitly; dropping rolls back.
pub async fn begin<'a>(db: &'a mut toasty::Db, ctx: &Context) -> AppResult<Transaction<'a>> {
    let mut tx = db.transaction().await.map_err(orm_err)?;
    ctx.apply(&mut tx).await?;
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
