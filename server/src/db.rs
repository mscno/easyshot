//! PostgreSQL access for the repository layer (sqlx), plus the migration runner.
//!
//! Values are `NULL`, 64-bit integers or text; ids are UUID strings, timestamps epoch
//! milliseconds, booleans 0/1. Placeholders are `$1, $2, ...`.
//!
//! Two roles: migrations run as the table owner (`MIGRATION_DATABASE_URL`); the server
//! connects as `shotglass_app`, which is `NOSUPERUSER NOBYPASSRLS`, so row-level security
//! applies. A plain [`Db`] carries no tenant context and therefore sees no rows of
//! owner-scoped tables; use [`Db::scoped`] for those (see [`Context`]).

use std::sync::Arc;
use std::time::Duration;

use sqlx::postgres::{PgConnection, PgPoolOptions, PgRow, PgTypeInfo};
use sqlx::{Column, Connection, Row as _, TypeInfo, ValueRef};
use uuid::Uuid;

use crate::config::Config;

#[derive(Debug, thiserror::Error)]
pub enum DbError {
    #[error("unique constraint violated")]
    UniqueViolation,
    #[error("{0}")]
    Other(String),
}

pub type DbResult<T> = Result<T, DbError>;

impl From<sqlx::Error> for DbError {
    fn from(e: sqlx::Error) -> Self {
        match &e {
            sqlx::Error::Database(d) if d.is_unique_violation() => DbError::UniqueViolation,
            _ => DbError::Other(e.to_string()),
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    Null,
    Int(i64),
    Text(String),
}

impl From<i64> for Value {
    fn from(v: i64) -> Self {
        Value::Int(v)
    }
}
impl From<i32> for Value {
    fn from(v: i32) -> Self {
        Value::Int(v as i64)
    }
}
impl From<bool> for Value {
    fn from(v: bool) -> Self {
        Value::Int(v as i64)
    }
}
impl From<&str> for Value {
    fn from(v: &str) -> Self {
        Value::Text(v.to_string())
    }
}
impl From<String> for Value {
    fn from(v: String) -> Self {
        Value::Text(v)
    }
}
impl From<&String> for Value {
    fn from(v: &String) -> Self {
        Value::Text(v.clone())
    }
}
impl From<Uuid> for Value {
    fn from(v: Uuid) -> Self {
        Value::Text(v.to_string())
    }
}
impl<T: Into<Value>> From<Option<T>> for Value {
    fn from(v: Option<T>) -> Self {
        v.map(Into::into).unwrap_or(Value::Null)
    }
}

/// Build a `[Value; N]`: `db.query(sql, &vals![id, 5, "x"])`.
#[macro_export]
macro_rules! vals {
    ($($v:expr),* $(,)?) => { [$($crate::db::Value::from($v)),*] };
}

#[derive(Debug, Clone)]
pub struct Row(Vec<Value>);

impl Row {
    pub fn len(&self) -> usize {
        self.0.len()
    }
    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }
    fn value(&self, i: usize) -> DbResult<&Value> {
        self.0
            .get(i)
            .ok_or_else(|| DbError::Other(format!("column {i} out of range")))
    }
    pub fn opt_i64(&self, i: usize) -> DbResult<Option<i64>> {
        match self.value(i)? {
            Value::Null => Ok(None),
            Value::Int(n) => Ok(Some(*n)),
            Value::Text(_) => Err(DbError::Other(format!("column {i}: expected integer"))),
        }
    }
    pub fn i64(&self, i: usize) -> DbResult<i64> {
        self.opt_i64(i)?
            .ok_or_else(|| DbError::Other(format!("column {i}: unexpected NULL")))
    }
    pub fn opt_text(&self, i: usize) -> DbResult<Option<String>> {
        match self.value(i)? {
            Value::Null => Ok(None),
            Value::Text(s) => Ok(Some(s.clone())),
            Value::Int(_) => Err(DbError::Other(format!("column {i}: expected text"))),
        }
    }
    pub fn text(&self, i: usize) -> DbResult<String> {
        self.opt_text(i)?
            .ok_or_else(|| DbError::Other(format!("column {i}: unexpected NULL")))
    }
    pub fn uuid(&self, i: usize) -> DbResult<Uuid> {
        Uuid::parse_str(&self.text(i)?).map_err(|e| DbError::Other(format!("column {i}: {e}")))
    }
}

/// `${start},${start+1},...` for `n` placeholders, for building `IN (...)` lists.
pub fn placeholders(start: usize, n: usize) -> String {
    (start..start + n)
        .map(|i| format!("${i}"))
        .collect::<Vec<_>>()
        .join(",")
}

/// Row-level-security context, applied with `set_config(..., true)` at the start of each
/// transaction. Unset values are empty strings, which no policy matches.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Context {
    /// `app.user_id`: the signed-in principal; owner policies match it.
    pub user_id: Option<String>,
    /// `app.workspace_id`: reserved for team workspaces.
    pub workspace_id: Option<String>,
    /// `app.share_slug`: the one share link being resolved (read-only access to that item).
    pub share_slug: Option<String>,
    /// `app.share_item_id`: the resolved item; viewers may read and add conversation rows.
    pub share_item_id: Option<String>,
    /// `app.rls_bypass = 'maintenance'`: retention jobs only (`Context::maintenance`).
    pub bypass: Option<&'static str>,
}

impl Context {
    pub fn user(id: Uuid) -> Context {
        Context {
            user_id: Some(id.to_string()),
            ..Context::default()
        }
    }

    /// RLS BYPASS PATH: retention and account purge across all owners. Only the expire
    /// job and account purge use it.
    pub fn maintenance() -> Context {
        Context {
            bypass: Some("maintenance"),
            ..Context::default()
        }
    }

    /// The statement that installs this context; one round trip.
    pub const SQL: &'static str = "SELECT set_config('app.user_id', $1, true), \
         set_config('app.workspace_id', $2, true), set_config('app.share_slug', $3, true), \
         set_config('app.share_item_id', $4, true), set_config('app.rls_bypass', $5, true)";

    pub fn params(&self) -> [String; 5] {
        [
            self.user_id.clone().unwrap_or_default(),
            self.workspace_id.clone().unwrap_or_default(),
            self.share_slug.clone().unwrap_or_default(),
            self.share_item_id.clone().unwrap_or_default(),
            self.bypass.unwrap_or_default().to_string(),
        ]
    }

    pub async fn apply(&self, conn: &mut PgConnection) -> DbResult<()> {
        let mut q = sqlx::query(Self::SQL);
        for p in self.params() {
            q = q.bind(p);
        }
        q.execute(conn).await?;
        Ok(())
    }
}

/// The app-role pool, optionally bound to an RLS [`Context`].
#[derive(Clone)]
pub struct Db {
    pool: sqlx::PgPool,
    context: Option<Arc<Context>>,
}

/// An argument that binds as a NULL of unspecified type (OID 0), so Postgres infers the type
/// from context instead of rejecting e.g. text NULL into a bigint column.
struct PgNull;

impl sqlx::Type<sqlx::Postgres> for PgNull {
    fn type_info() -> PgTypeInfo {
        PgTypeInfo::with_oid(sqlx::postgres::types::Oid(0))
    }
    fn compatible(_: &PgTypeInfo) -> bool {
        true
    }
}
impl sqlx::Encode<'_, sqlx::Postgres> for PgNull {
    fn encode_by_ref(
        &self,
        _: &mut sqlx::postgres::PgArgumentBuffer,
    ) -> Result<sqlx::encode::IsNull, sqlx::error::BoxDynError> {
        Ok(sqlx::encode::IsNull::Yes)
    }
}

fn pg_row(row: &PgRow) -> DbResult<Row> {
    let mut out = Vec::with_capacity(row.columns().len());
    for (i, col) in row.columns().iter().enumerate() {
        if row.try_get_raw(i)?.is_null() {
            out.push(Value::Null);
            continue;
        }
        let v = match col.type_info().name() {
            "INT2" => Value::Int(row.try_get::<i16, _>(i)? as i64),
            "INT4" => Value::Int(row.try_get::<i32, _>(i)? as i64),
            "INT8" => Value::Int(row.try_get::<i64, _>(i)?),
            "BOOL" => Value::Int(row.try_get::<bool, _>(i)? as i64),
            _ => Value::Text(row.try_get::<String, _>(i)?),
        };
        out.push(v);
    }
    Ok(Row(out))
}

fn bind<'q>(
    mut q: sqlx::query::Query<'q, sqlx::Postgres, sqlx::postgres::PgArguments>,
    params: &'q [Value],
) -> sqlx::query::Query<'q, sqlx::Postgres, sqlx::postgres::PgArguments> {
    // Untyped NULLs make Postgres infer the parameter type per statement; a cached prepared
    // statement would pin that type and break later calls that bind a value there.
    if params.contains(&Value::Null) {
        q = q.persistent(false);
    }
    for p in params {
        q = match p {
            Value::Null => q.bind(PgNull),
            Value::Int(n) => q.bind(*n),
            Value::Text(s) => q.bind(s.as_str()),
        };
    }
    q
}

impl Db {
    /// Lazy app-role pool: no network I/O happens until the first query.
    pub fn connect(cfg: &Config) -> DbResult<Db> {
        let url = cfg.database_url.trim();
        if !(url.starts_with("postgres://") || url.starts_with("postgresql://")) {
            return Err(DbError::Other(
                "DATABASE_URL must start with postgres:// or postgresql://".into(),
            ));
        }
        let pool = PgPoolOptions::new()
            .max_connections(cfg.db_max_connections)
            .acquire_timeout(Duration::from_secs(5))
            .connect_lazy(url)?;
        Ok(Db::from_pool(pool))
    }

    pub fn from_pool(pool: sqlx::PgPool) -> Db {
        Db {
            pool,
            context: None,
        }
    }

    pub fn pool(&self) -> &sqlx::PgPool {
        &self.pool
    }

    /// The same pool, running every statement in a transaction that first applies `ctx`.
    pub fn scoped(&self, ctx: Context) -> Db {
        Db {
            pool: self.pool.clone(),
            context: Some(Arc::new(ctx)),
        }
    }

    pub async fn execute(&self, sql: &str, params: &[Value]) -> DbResult<u64> {
        match &self.context {
            None => Ok(bind(sqlx::query(sql), params)
                .execute(&self.pool)
                .await?
                .rows_affected()),
            Some(ctx) => {
                let mut tx = self.pool.begin().await?;
                ctx.apply(&mut tx).await?;
                let n = bind(sqlx::query(sql), params)
                    .execute(&mut *tx)
                    .await?
                    .rows_affected();
                tx.commit().await?;
                Ok(n)
            }
        }
    }

    pub async fn query(&self, sql: &str, params: &[Value]) -> DbResult<Vec<Row>> {
        let rows = match &self.context {
            None => bind(sqlx::query(sql), params).fetch_all(&self.pool).await?,
            Some(ctx) => {
                let mut tx = self.pool.begin().await?;
                ctx.apply(&mut tx).await?;
                let rows = bind(sqlx::query(sql), params).fetch_all(&mut *tx).await?;
                tx.commit().await?;
                rows
            }
        };
        rows.iter().map(pg_row).collect()
    }

    pub async fn query_opt(&self, sql: &str, params: &[Value]) -> DbResult<Option<Row>> {
        Ok(self.query(sql, params).await?.into_iter().next())
    }

    pub async fn query_one(&self, sql: &str, params: &[Value]) -> DbResult<Row> {
        self.query_opt(sql, params)
            .await?
            .ok_or_else(|| DbError::Other("expected one row, got none".into()))
    }
}

// ---------- migrations (owner role) ----------

include!(concat!(env!("OUT_DIR"), "/migrations.rs"));

/// Serializes concurrent migration runs (deploy release command vs. local tasks).
const MIGRATION_LOCK: i64 = 0x5347_4d49_4752; // "SGMIGR"

async fn owner_conn(url: &str) -> DbResult<PgConnection> {
    Ok(PgConnection::connect(url).await?)
}

async fn applied(conn: &mut PgConnection) -> DbResult<Vec<String>> {
    let exists: Option<String> = sqlx::query_scalar("SELECT to_regclass('_migrations')::text")
        .fetch_one(&mut *conn)
        .await?;
    if exists.is_none() {
        sqlx::raw_sql(
            "CREATE TABLE _migrations (name TEXT PRIMARY KEY, applied_at BIGINT NOT NULL)",
        )
        .execute(&mut *conn)
        .await?;
    }
    Ok(
        sqlx::query_scalar("SELECT name FROM _migrations ORDER BY name")
            .fetch_all(&mut *conn)
            .await?,
    )
}

/// Apply pending migrations as the table owner. Each file runs in its own transaction.
pub async fn migrate(owner_url: &str) -> DbResult<Vec<&'static str>> {
    let mut conn = owner_conn(owner_url).await?;
    migrate_conn(&mut conn).await
}

pub async fn migrate_conn(conn: &mut PgConnection) -> DbResult<Vec<&'static str>> {
    sqlx::query("SELECT pg_advisory_lock($1)")
        .bind(MIGRATION_LOCK)
        .execute(&mut *conn)
        .await?;
    let result = async {
        let done = applied(conn).await?;
        let mut ran = Vec::new();
        for (name, sql) in MIGRATIONS {
            if done.iter().any(|d| d == name) {
                continue;
            }
            let mut tx = conn.begin().await?;
            sqlx::raw_sql(sql)
                .execute(&mut *tx)
                .await
                .map_err(|e| DbError::Other(format!("migration {name}: {e}")))?;
            sqlx::query("INSERT INTO _migrations (name, applied_at) VALUES ($1, $2)")
                .bind(*name)
                .bind(chrono::Utc::now().timestamp_millis())
                .execute(&mut *tx)
                .await?;
            tx.commit().await?;
            ran.push(*name);
        }
        Ok(ran)
    }
    .await;
    let _ = sqlx::query("SELECT pg_advisory_unlock($1)")
        .bind(MIGRATION_LOCK)
        .execute(&mut *conn)
        .await;
    result
}

/// `(name, applied)` for every embedded migration.
pub async fn status(owner_url: &str) -> DbResult<Vec<(&'static str, bool)>> {
    let mut conn = owner_conn(owner_url).await?;
    let done = applied(&mut conn).await?;
    Ok(MIGRATIONS
        .iter()
        .map(|(n, _)| (*n, done.iter().any(|d| d == n)))
        .collect())
}

/// Drop and recreate the `public` schema, then migrate. Refuses anything but a database
/// whose name ends in `_dev` or `_test`.
pub async fn reset(owner_url: &str) -> DbResult<Vec<&'static str>> {
    let db = owner_url
        .rsplit('/')
        .next()
        .unwrap_or("")
        .split('?')
        .next()
        .unwrap_or("");
    if !(db.ends_with("_dev") || db.ends_with("_test")) {
        return Err(DbError::Other(format!(
            "refusing to reset database {db:?}: only *_dev or *_test databases"
        )));
    }
    let mut conn = owner_conn(owner_url).await?;
    sqlx::raw_sql("DROP SCHEMA IF EXISTS public CASCADE; CREATE SCHEMA public;")
        .execute(&mut conn)
        .await?;
    migrate_conn(&mut conn).await
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn builds_placeholder_lists() {
        assert_eq!(placeholders(1, 3), "$1,$2,$3");
        assert_eq!(placeholders(2, 2), "$2,$3");
        assert_eq!(placeholders(1, 0), "");
    }

    #[test]
    fn migrations_are_embedded_in_order() {
        assert!(MIGRATIONS.len() >= 4);
        assert!(MIGRATIONS.windows(2).all(|w| w[0].0 < w[1].0));
        assert_eq!(MIGRATIONS[0].0, "0001_init");
    }

    #[test]
    fn value_conversions() {
        assert_eq!(Value::from(Some(3i64)), Value::Int(3));
        assert_eq!(Value::from(None::<String>), Value::Null);
        assert_eq!(Value::from(true), Value::Int(1));
        assert_eq!(Value::from("x"), Value::Text("x".into()));
    }

    #[test]
    fn context_params() {
        let u = Uuid::nil();
        assert_eq!(Context::user(u).params()[0], u.to_string());
        assert_eq!(Context::default().params(), <[String; 5]>::default());
        assert_eq!(Context::maintenance().params()[4], "maintenance");
    }
}
