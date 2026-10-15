//! Portable database layer over Postgres (sqlx) and SQLite/libSQL/Turso (libsql).
//!
//! All SQL in the app is written once, in a dialect both engines accept, with `?1, ?2, ...`
//! placeholders. The Postgres backend rewrites `?N` to `$N`. Values are `NULL`, 64-bit
//! integers or text; ids are UUID strings, timestamps are epoch milliseconds, booleans 0/1.

use std::sync::Arc;
use std::time::Duration;

use sqlx::postgres::{PgPoolOptions, PgRow, PgTypeInfo};
use sqlx::{Column, Row as _, TypeInfo, ValueRef};
use tokio::sync::OnceCell;
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

impl From<libsql::Error> for DbError {
    fn from(e: libsql::Error) -> Self {
        let msg = e.to_string();
        if msg.contains("UNIQUE constraint failed") || msg.contains("PRIMARY KEY constraint failed")
        {
            DbError::UniqueViolation
        } else {
            DbError::Other(msg)
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

/// Rewrite `?N` placeholders (outside single-quoted literals) to Postgres `$N`.
pub fn rewrite_placeholders(sql: &str) -> String {
    let mut out = String::with_capacity(sql.len());
    let mut in_str = false;
    let mut chars = sql.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '\'' => {
                in_str = !in_str;
                out.push(c);
            }
            '?' if !in_str && chars.peek().is_some_and(|d| d.is_ascii_digit()) => out.push('$'),
            _ => out.push(c),
        }
    }
    out
}

/// `?{start},?{start+1},...` for `n` placeholders, for building `IN (...)` lists.
pub fn placeholders(start: usize, n: usize) -> String {
    (start..start + n)
        .map(|i| format!("?{i}"))
        .collect::<Vec<_>>()
        .join(",")
}

pub struct LibsqlDb {
    url: String,
    auth_token: Option<String>,
    conn: OnceCell<libsql::Connection>,
}

#[derive(Clone)]
pub enum Db {
    Pg(sqlx::PgPool),
    Libsql(Arc<LibsqlDb>),
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

impl Db {
    /// Cheap and lazy: no network I/O or file access happens until the first query.
    pub fn connect(cfg: &Config) -> DbResult<Db> {
        let url = cfg.database_url.trim();
        if url.starts_with("postgres://") || url.starts_with("postgresql://") {
            let pool = PgPoolOptions::new()
                .max_connections(cfg.db_max_connections)
                .acquire_timeout(Duration::from_secs(5))
                .connect_lazy(url)?;
            Ok(Db::Pg(pool))
        } else if ["libsql://", "https://", "http://", "file:"]
            .iter()
            .any(|p| url.starts_with(p))
        {
            Ok(Db::Libsql(Arc::new(LibsqlDb {
                url: url.to_string(),
                auth_token: cfg.database_auth_token.clone(),
                conn: OnceCell::new(),
            })))
        } else {
            Err(DbError::Other(
                "DATABASE_URL must start with postgres://, postgresql://, libsql://, https://, http:// or file:"
                    .into(),
            ))
        }
    }

    pub fn backend(&self) -> &'static str {
        match self {
            Db::Pg(_) => "postgres",
            Db::Libsql(_) => "libsql",
        }
    }

    pub async fn execute(&self, sql: &str, params: &[Value]) -> DbResult<u64> {
        match self {
            Db::Pg(pool) => {
                let sql = rewrite_placeholders(sql);
                let r = pg_bind(sqlx::query(&sql), params).execute(pool).await?;
                Ok(r.rows_affected())
            }
            Db::Libsql(l) => Ok(l.conn().await?.execute(sql, lq_params(params)).await?),
        }
    }

    pub async fn query(&self, sql: &str, params: &[Value]) -> DbResult<Vec<Row>> {
        match self {
            Db::Pg(pool) => {
                let sql = rewrite_placeholders(sql);
                let rows = pg_bind(sqlx::query(&sql), params).fetch_all(pool).await?;
                rows.iter().map(pg_row).collect()
            }
            Db::Libsql(l) => {
                let mut rows = l.conn().await?.query(sql, lq_params(params)).await?;
                let mut out = Vec::new();
                while let Some(row) = rows.next().await? {
                    let mut cols = Vec::with_capacity(row.column_count() as usize);
                    for i in 0..row.column_count() {
                        cols.push(match row.get_value(i)? {
                            libsql::Value::Null => Value::Null,
                            libsql::Value::Integer(n) => Value::Int(n),
                            libsql::Value::Real(f) => Value::Int(f as i64),
                            libsql::Value::Text(s) => Value::Text(s),
                            libsql::Value::Blob(_) => {
                                return Err(DbError::Other("unexpected blob column".into()))
                            }
                        });
                    }
                    out.push(Row(cols));
                }
                Ok(out)
            }
        }
    }

    pub async fn query_opt(&self, sql: &str, params: &[Value]) -> DbResult<Option<Row>> {
        Ok(self.query(sql, params).await?.into_iter().next())
    }

    pub async fn query_one(&self, sql: &str, params: &[Value]) -> DbResult<Row> {
        self.query_opt(sql, params)
            .await?
            .ok_or_else(|| DbError::Other("expected one row, got none".into()))
    }

    /// Apply pending migrations (embedded, portable SQL; tracked in `_migrations`).
    pub async fn migrate(&self) -> DbResult<()> {
        self.execute(
            "CREATE TABLE IF NOT EXISTS _migrations (name TEXT PRIMARY KEY, applied_at BIGINT NOT NULL)",
            &[],
        )
        .await?;
        let applied: Vec<String> = self
            .query("SELECT name FROM _migrations", &[])
            .await?
            .iter()
            .map(|r| r.text(0))
            .collect::<DbResult<_>>()?;
        for (name, sql) in MIGRATIONS {
            if applied.iter().any(|a| a == name) {
                continue;
            }
            for stmt in split_statements(sql) {
                self.execute(&stmt, &[]).await?;
            }
            self.execute(
                "INSERT INTO _migrations (name, applied_at) VALUES (?1, ?2)",
                &vals![*name, chrono::Utc::now().timestamp_millis()],
            )
            .await?;
        }
        Ok(())
    }
}

pub const MIGRATIONS: &[(&str, &str)] = &[
    ("0001_init", include_str!("../migrations/0001_init.sql")),
    (
        "0002_auth_codes",
        include_str!("../migrations/0002_auth_codes.sql"),
    ),
];

/// Split a migration file on `;`, dropping `--` comment lines and blanks.
pub fn split_statements(sql: &str) -> Vec<String> {
    let cleaned: String = sql
        .lines()
        .filter(|l| !l.trim_start().starts_with("--"))
        .collect::<Vec<_>>()
        .join("\n");
    cleaned
        .split(';')
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect()
}

fn pg_bind<'q>(
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

fn lq_params(params: &[Value]) -> Vec<libsql::Value> {
    params
        .iter()
        .map(|p| match p {
            Value::Null => libsql::Value::Null,
            Value::Int(n) => libsql::Value::Integer(*n),
            Value::Text(s) => libsql::Value::Text(s.clone()),
        })
        .collect()
}

impl LibsqlDb {
    /// One connection, created on first use and shared by all requests. Remote (Turso/sqld)
    /// connections are stateless HTTP clients, so sharing one avoids reconnect churn.
    async fn conn(&self) -> DbResult<&libsql::Connection> {
        self.conn
            .get_or_try_init(|| async {
                let u = &self.url;
                let db = if let Some(rest) = u.strip_prefix("file:") {
                    // `file:rel.db`, `file:///abs.db` and `file::memory:`.
                    let path = rest.strip_prefix("//").unwrap_or(rest).to_string();
                    libsql::Builder::new_local(path).build().await?
                } else {
                    let url = u.replacen("libsql://", "https://", 1);
                    libsql::Builder::new_remote(url, self.auth_token.clone().unwrap_or_default())
                        .build()
                        .await?
                };
                let conn = db.connect()?;
                if u.starts_with("file:") {
                    let _ = conn.busy_timeout(Duration::from_secs(5));
                }
                Ok::<_, libsql::Error>(conn)
            })
            .await
            .map_err(Into::into)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rewrites_placeholders() {
        assert_eq!(
            rewrite_placeholders("SELECT * FROM t WHERE a = ?1 AND b = ?2 OR c = ?1"),
            "SELECT * FROM t WHERE a = $1 AND b = $2 OR c = $1"
        );
        assert_eq!(
            rewrite_placeholders("SELECT '?1 is literal', ?10"),
            "SELECT '?1 is literal', $10"
        );
        assert_eq!(rewrite_placeholders("SELECT 1"), "SELECT 1");
    }

    #[test]
    fn builds_placeholder_lists() {
        assert_eq!(placeholders(1, 3), "?1,?2,?3");
        assert_eq!(placeholders(2, 2), "?2,?3");
        assert_eq!(placeholders(1, 0), "");
    }

    #[test]
    fn splits_migrations() {
        let s = split_statements("-- c\nCREATE TABLE a (x INT);\n\nCREATE INDEX i ON a (x);\n");
        assert_eq!(s, vec!["CREATE TABLE a (x INT)", "CREATE INDEX i ON a (x)"]);
        for (_, sql) in MIGRATIONS {
            assert!(!split_statements(sql).is_empty());
        }
    }

    #[test]
    fn value_conversions() {
        assert_eq!(Value::from(Some(3i64)), Value::Int(3));
        assert_eq!(Value::from(None::<String>), Value::Null);
        assert_eq!(Value::from(true), Value::Int(1));
        assert_eq!(Value::from("x"), Value::Text("x".into()));
    }

    #[tokio::test]
    async fn libsql_local_roundtrip_and_unique() {
        let cfg = Config::for_tests("file::memory:");
        let db = Db::connect(&cfg).unwrap();
        db.migrate().await.unwrap();
        db.migrate().await.unwrap(); // idempotent
        let ins = "INSERT INTO login_attempts (id, email, ip, succeeded, created_at) VALUES (?1, ?2, ?3, ?4, ?5)";
        db.execute(ins, &vals!["a", "e@x.y", None::<String>, true, 5i64])
            .await
            .unwrap();
        let err = db
            .execute(ins, &vals!["a", "e@x.y", "1.2.3.4", false, 6i64])
            .await
            .unwrap_err();
        assert!(matches!(err, DbError::UniqueViolation), "{err:?}");
        let r = db
            .query_one("SELECT id, ip, succeeded FROM login_attempts", &[])
            .await
            .unwrap();
        assert_eq!(r.text(0).unwrap(), "a");
        assert_eq!(r.opt_text(1).unwrap(), None);
        assert_eq!(r.i64(2).unwrap(), 1);
        assert!(db
            .query_opt("SELECT id FROM login_attempts WHERE id = ?1", &vals!["zz"])
            .await
            .unwrap()
            .is_none());
    }
}
