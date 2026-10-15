//! Toasty on top of the portable [`Db`].
//!
//! The video domain is modelled with Toasty (`crate::video::model`), but its queries run
//! through this driver over the same `Db` handle as the rest of the server: one pool on
//! Postgres, one shared libSQL connection on Turso or a local file. Toasty serializes each
//! statement with the matching dialect (SQLite for libSQL, PostgreSQL for Postgres); this
//! driver only binds values and maps rows back.
//!
//! Schema ownership: every table, Toasty-modelled or not, is created by the embedded
//! migrations in `migrations/` (`Db::migrate`). Toasty never pushes or migrates schema here;
//! `push_schema`, `apply_migration` and `reset_db` are refused. Models use only `String`
//! (UUID strings, text) and `i64` (epoch milliseconds, counters, 0/1 flags) fields, matching
//! the portable column conventions.
//!
//! Transactions are refused: the libSQL handle is a single connection shared by concurrent
//! requests, so a `BEGIN` there would capture unrelated statements. Video writes are single
//! statements or idempotent sequences, like the existing repository code.

use std::borrow::Cow;
use std::fmt;
use std::sync::Arc;

use async_trait::async_trait;
use toasty_core::driver::operation::{Operation, RawSqlRet, TypedValue};
use toasty_core::driver::{Capability, ConnectContext, Driver, ExecResponse};
use toasty_core::schema::db::{AppliedMigration, Migration};
use toasty_core::schema::diff;
use toasty_core::{stmt, Schema};
use toasty_sql as sql;

use crate::db::{Db, DbError, Row, Value};

/// Build the Toasty handle for the video models over `db`. No I/O happens here.
pub async fn connect(db: &Db) -> toasty::Result<toasty::Db> {
    toasty::Db::builder()
        .models(crate::video::model::models())
        .build(DbDriver { db: db.clone() })
        .await
}

/// True when a Toasty error came from a unique-constraint violation in the database.
pub fn is_unique_violation(e: &toasty::Error) -> bool {
    e.to_string().contains(UNIQUE_MSG)
}

const UNIQUE_MSG: &str = "unique constraint violated";

pub struct DbDriver {
    db: Db,
}

impl fmt::Debug for DbDriver {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("DbDriver")
            .field("backend", &self.db.backend())
            .finish()
    }
}

fn capability(db: &Db) -> &'static Capability {
    match db {
        Db::Pg(_) => &Capability::POSTGRESQL,
        Db::Libsql(_) => &Capability::SQLITE,
    }
}

#[async_trait]
impl Driver for DbDriver {
    fn url(&self) -> Cow<'_, str> {
        Cow::Owned(format!("shotglass-db:{}", self.db.backend()))
    }

    fn capability(&self) -> &'static Capability {
        capability(&self.db)
    }

    async fn connect(&self, _cx: &ConnectContext) -> toasty::Result<Box<dyn toasty_core::Connection>> {
        Ok(Box::new(DbConnection {
            db: self.db.clone(),
        }))
    }

    fn generate_migration(&self, _diff: &diff::Schema<'_>) -> Migration {
        // Schema is owned by `migrations/*.sql`; nothing is generated from models.
        Migration::new_sql_with_breakpoints::<&str>(&[])
    }

    async fn reset_db(&self) -> toasty::Result<()> {
        Err(schema_owned())
    }
}

fn schema_owned() -> toasty::Error {
    toasty::Error::unsupported_feature("schema is managed by migrations/*.sql (Db::migrate)")
}

pub struct DbConnection {
    db: Db,
}

impl fmt::Debug for DbConnection {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("DbConnection")
    }
}

#[derive(Debug, thiserror::Error)]
#[error("{0}")]
struct BridgeError(String);

fn db_err(e: DbError) -> toasty::Error {
    let msg = match e {
        DbError::UniqueViolation => UNIQUE_MSG.to_string(),
        DbError::Other(m) => m,
    };
    toasty::Error::driver_operation_failed(BridgeError(msg))
}

fn bind(params: Vec<TypedValue>) -> toasty::Result<Vec<Value>> {
    params
        .into_iter()
        .map(|p| {
            Ok(match p.value {
                stmt::Value::Null => Value::Null,
                stmt::Value::Bool(b) => Value::Int(b as i64),
                stmt::Value::I8(n) => Value::Int(n as i64),
                stmt::Value::I16(n) => Value::Int(n as i64),
                stmt::Value::I32(n) => Value::Int(n as i64),
                stmt::Value::I64(n) => Value::Int(n),
                stmt::Value::U8(n) => Value::Int(n as i64),
                stmt::Value::U16(n) => Value::Int(n as i64),
                stmt::Value::U32(n) => Value::Int(n as i64),
                stmt::Value::U64(n) => Value::Int(
                    i64::try_from(n).map_err(|_| unsupported("u64 value out of range"))?,
                ),
                stmt::Value::String(s) => Value::Text(s),
                stmt::Value::Uuid(u) => Value::Text(u.to_string()),
                other => return Err(unsupported(&format!("bind value {other:?}"))),
            })
        })
        .collect()
}

fn unsupported(what: &str) -> toasty::Error {
    toasty::Error::unsupported_feature(format!("shotglass Db bridge: {what}"))
}

fn column(row: &Row, i: usize, ty: Option<&stmt::Type>) -> toasty::Result<stmt::Value> {
    let int = row.opt_i64(i);
    let v = match int {
        Ok(None) => return Ok(stmt::Value::Null),
        Ok(Some(n)) => match ty {
            None | Some(stmt::Type::I64) => stmt::Value::I64(n),
            Some(stmt::Type::I32) => stmt::Value::I32(n as i32),
            Some(stmt::Type::I16) => stmt::Value::I16(n as i16),
            Some(stmt::Type::I8) => stmt::Value::I8(n as i8),
            Some(stmt::Type::U64) => stmt::Value::U64(n as u64),
            Some(stmt::Type::U32) => stmt::Value::U32(n as u32),
            Some(stmt::Type::U16) => stmt::Value::U16(n as u16),
            Some(stmt::Type::U8) => stmt::Value::U8(n as u8),
            Some(stmt::Type::Bool) => stmt::Value::Bool(n != 0),
            Some(other) => return Err(unsupported(&format!("integer column as {other:?}"))),
        },
        // Not an integer: it is text (the portable layer only yields NULL/int/text).
        Err(_) => {
            let s = row.text(i).map_err(db_err)?;
            match ty {
                None | Some(stmt::Type::String) => stmt::Value::String(s),
                Some(stmt::Type::Uuid) => stmt::Value::Uuid(
                    s.parse()
                        .map_err(|_| unsupported("text column is not a UUID"))?,
                ),
                Some(other) => return Err(unsupported(&format!("text column as {other:?}"))),
            }
        }
    };
    Ok(v)
}

enum Ret {
    Count,
    Infer,
    Types(Vec<stmt::Type>),
}

impl DbConnection {
    async fn run(&self, sql: &str, params: Vec<TypedValue>, ret: Ret) -> toasty::Result<ExecResponse> {
        let params = bind(params)?;
        if matches!(ret, Ret::Count) {
            let n = self.db.execute(sql, &params).await.map_err(db_err)?;
            return Ok(ExecResponse::count(n));
        }
        let rows = self.db.query(sql, &params).await.map_err(db_err)?;
        let mut out = Vec::with_capacity(rows.len());
        for row in &rows {
            let items = match &ret {
                Ret::Count => unreachable!(),
                Ret::Infer => (0..row.len())
                    .map(|i| column(row, i, None))
                    .collect::<toasty::Result<Vec<_>>>()?,
                Ret::Types(tys) => tys
                    .iter()
                    .enumerate()
                    .map(|(i, ty)| column(row, i, Some(ty)))
                    .collect::<toasty::Result<Vec<_>>>()?,
            };
            out.push(stmt::ValueRecord::from_vec(items).into());
        }
        Ok(ExecResponse::value_stream(stmt::ValueStream::from_vec(out)))
    }
}

#[async_trait]
impl toasty_core::driver::Connection for DbConnection {
    async fn exec(&mut self, schema: &Arc<Schema>, op: Operation) -> toasty::Result<ExecResponse> {
        let (statement, params, ret_tys) = match op {
            Operation::Insert(op) => (sql::Statement::from(op.stmt), op.params, op.ret),
            Operation::QuerySql(op) => (sql::Statement::from(op.stmt), op.params, op.ret),
            Operation::RawSql(op) => {
                let ret = match op.ret {
                    RawSqlRet::None => Ret::Count,
                    RawSqlRet::Infer => Ret::Infer,
                    RawSqlRet::Types(t) => Ret::Types(t),
                };
                return self.run(&op.sql, op.params, ret).await;
            }
            Operation::Transaction(_) => {
                return Err(unsupported(
                    "transactions (the libSQL connection is shared between requests)",
                ))
            }
            other => return Err(unsupported(&format!("operation {}", other.name()))),
        };
        let ret = match (statement.returning_len(), ret_tys) {
            (Some(_), Some(tys)) => Ret::Types(tys),
            (Some(_), None) => Ret::Infer,
            (None, _) => Ret::Count,
        };
        let text = match &self.db {
            Db::Pg(_) => sql::Serializer::postgresql(&schema.db).serialize(&statement),
            Db::Libsql(_) => sql::Serializer::sqlite(&schema.db).serialize(&statement),
        };
        self.run(&text, params, ret).await
    }

    async fn push_schema(&mut self, _schema: &Schema) -> toasty::Result<()> {
        Err(schema_owned())
    }

    async fn applied_migrations(&mut self) -> toasty::Result<Vec<AppliedMigration>> {
        Ok(Vec::new())
    }

    async fn apply_migration(&mut self, _id: u64, _name: &str, _m: &Migration) -> toasty::Result<()> {
        Err(schema_owned())
    }
}
