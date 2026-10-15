//! PostgreSQL access through one Toasty pool, plus the migration runner.
//!
//! The repository layer issues raw SQL through Toasty (`toasty::sql`); the video domain
//! uses Toasty models on the same pool (see [`Db::toasty`] and `crate::orm`). Values are
//! `NULL`, 64-bit integers or text; ids are UUID strings, timestamps epoch milliseconds,
//! booleans 0/1. Placeholders are `$1, $2, ...`.
//!
//! Two roles: migrations run as the table owner (`MIGRATION_DATABASE_URL`) over a single
//! `tokio-postgres` connection ([`crate::pg`]); the server connects as `easyshot_app`,
//! which is `NOSUPERUSER NOBYPASSRLS`, so row-level security applies. A plain [`Db`]
//! carries no tenant context and therefore sees no rows of owner-scoped tables; use
//! [`Db::scoped`] for those (see [`Context`]).

use std::borrow::Cow;
use std::sync::Arc;
use std::time::Duration;

use tokio_postgres::Client;
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

impl From<toasty::Error> for DbError {
    fn from(e: toasty::Error) -> Self {
        if crate::orm::is_unique_violation(&e) {
            return DbError::UniqueViolation;
        }
        DbError::Other(e.to_string())
    }
}

impl From<tokio_postgres::Error> for DbError {
    fn from(e: tokio_postgres::Error) -> Self {
        crate::pg::pg_err(e)
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

    /// Install this context on `tx` (the first statement of every scoped transaction).
    pub async fn apply(&self, tx: &mut dyn toasty::Executor) -> DbResult<()> {
        let mut q = toasty::sql::query(Self::SQL);
        for p in self.params() {
            q = q.bind(p);
        }
        q.exec(tx).await?;
        Ok(())
    }
}

/// Toasty binds every parameter with a concrete type, but a NULL's type depends on where
/// it lands (`text` into a `bigint` column fails). Inline NULLs as literals, which Postgres
/// types from context, and renumber the remaining placeholders. Quoted strings and
/// identifiers, dollar-quoted bodies and `--` comments are copied unchanged.
fn inline_nulls<'a>(sql: &'a str, params: &[Value]) -> (Cow<'a, str>, Vec<Value>) {
    if !params.contains(&Value::Null) {
        return (Cow::Borrowed(sql), params.to_vec());
    }
    let mut map = Vec::with_capacity(params.len());
    let mut kept = Vec::new();
    for p in params {
        if *p == Value::Null {
            map.push(None);
        } else {
            kept.push(p.clone());
            map.push(Some(kept.len()));
        }
    }
    let b = sql.as_bytes();
    let mut out = String::with_capacity(sql.len() + 8);
    let mut i = 0;
    while i < b.len() {
        let end = match b[i] {
            q @ (b'\'' | b'"') => sql[i + 1..].find(q as char).map_or(b.len(), |j| i + 2 + j),
            b'-' if b.get(i + 1) == Some(&b'-') => sql[i..].find('\n').map_or(b.len(), |j| i + j),
            b'$' if b.get(i + 1).is_some_and(u8::is_ascii_digit) => {
                let mut j = i + 1;
                while j < b.len() && b[j].is_ascii_digit() {
                    j += 1;
                }
                let n: usize = sql[i + 1..j].parse().unwrap_or(0);
                match map.get(n.wrapping_sub(1)) {
                    Some(Some(k)) => out.push_str(&format!("${k}")),
                    Some(None) => out.push_str("NULL"),
                    None => out.push_str(&sql[i..j]),
                }
                i = j;
                continue;
            }
            b'$' => match sql[i + 1..].find('$').map(|j| i + 2 + j) {
                // Dollar quote: `$tag$ ... $tag$`.
                Some(t)
                    if sql[i + 1..t - 1]
                        .chars()
                        .all(|c| c.is_alphanumeric() || c == '_') =>
                {
                    let tag = &sql[i..t];
                    sql[t..].find(tag).map_or(b.len(), |j| t + j + tag.len())
                }
                _ => i + 1,
            },
            _ => {
                let mut j = i + 1;
                while j < b.len() && !matches!(b[j], b'\'' | b'"' | b'-' | b'$') {
                    j += 1;
                }
                j
            }
        };
        out.push_str(&sql[i..end]);
        i = end;
    }
    (Cow::Owned(out), kept)
}

fn to_row(v: toasty::stmt::Value) -> DbResult<Row> {
    use toasty::stmt::Value as V;
    let V::Record(rec) = v else {
        return Err(DbError::Other(format!("expected a row, got {v:?}")));
    };
    rec.into_iter()
        .map(|f| {
            Ok(match f {
                V::Null => Value::Null,
                V::Bool(b) => Value::Int(b as i64),
                V::I8(n) => Value::Int(n.into()),
                V::I16(n) => Value::Int(n.into()),
                V::I32(n) => Value::Int(n.into()),
                V::I64(n) => Value::Int(n),
                V::U8(n) => Value::Int(n.into()),
                V::U16(n) => Value::Int(n.into()),
                V::U32(n) => Value::Int(n.into()),
                V::String(s) => Value::Text(s),
                V::Uuid(u) => Value::Text(u.to_string()),
                other => {
                    return Err(DbError::Other(format!(
                        "unsupported column value {other:?}"
                    )));
                }
            })
        })
        .collect::<DbResult<Vec<_>>>()
        .map(Row)
}

fn statement(sql: &str, params: &[Value]) -> toasty::sql::Statement {
    let (sql, params) = inline_nulls(sql, params);
    let mut q = toasty::sql::statement(sql.into_owned());
    for p in params {
        q = match p {
            Value::Int(n) => q.bind(n),
            Value::Text(s) => q.bind(s),
            Value::Null => unreachable!("NULLs are inlined"),
        };
    }
    q
}

fn query(sql: &str, params: &[Value]) -> toasty::sql::Query {
    let (sql, params) = inline_nulls(sql, params);
    let mut q = toasty::sql::query(sql.into_owned());
    for p in params {
        q = match p {
            Value::Int(n) => q.bind(n),
            Value::Text(s) => q.bind(s),
            Value::Null => unreachable!("NULLs are inlined"),
        };
    }
    q
}

/// Connections opened eagerly at startup so first requests skip the TCP/TLS/auth cost.
const WARM_CONNECTIONS: usize = 4;

/// The app-role Toasty pool, optionally bound to an RLS [`Context`].
#[derive(Clone)]
pub struct Db {
    orm: toasty::Db,
    context: Option<Arc<Context>>,
}

impl Db {
    /// The app-role pool, with up to [`WARM_CONNECTIONS`] connections opened up front.
    pub async fn connect(cfg: &Config) -> DbResult<Db> {
        Self::connect_url(cfg.database_url.trim(), cfg.db_max_connections as usize).await
    }

    pub async fn connect_url(url: &str, max: usize) -> DbResult<Db> {
        if !(url.starts_with("postgres://") || url.starts_with("postgresql://")) {
            return Err(DbError::Other(
                "DATABASE_URL must start with postgres:// or postgresql://".into(),
            ));
        }
        let max = max.max(1);
        let orm = toasty::Db::builder()
            .models(crate::video::model::models())
            .max_pool_size(max)
            .pool_wait_timeout(Some(Duration::from_secs(5)))
            .build(toasty_driver_postgresql::PostgreSQL::new(url)?)
            .await?;
        let db = Db { orm, context: None };
        db.warm(WARM_CONNECTIONS.min(max)).await?;
        Ok(db)
    }

    /// Hold `n` connections at once so the pool opens them, then return them idle.
    pub async fn warm(&self, n: usize) -> DbResult<()> {
        let conns =
            futures_util::future::try_join_all((0..n).map(|_| self.orm.connection())).await?;
        drop(conns);
        Ok(())
    }

    /// The Toasty handle (clones share the pool) for model queries; see `crate::orm`.
    pub fn toasty(&self) -> toasty::Db {
        self.orm.clone()
    }

    /// The same pool, running every statement in a transaction that first applies `ctx`.
    pub fn scoped(&self, ctx: Context) -> Db {
        Db {
            orm: self.orm.clone(),
            context: Some(Arc::new(ctx)),
        }
    }

    pub async fn execute(&self, sql: &str, params: &[Value]) -> DbResult<u64> {
        let mut db = self.orm.clone();
        match &self.context {
            None => Ok(statement(sql, params).exec(&mut db).await?),
            Some(ctx) => {
                let mut tx = db.transaction().await?;
                ctx.apply(&mut tx).await?;
                let n = statement(sql, params).exec(&mut tx).await?;
                tx.commit().await?;
                Ok(n)
            }
        }
    }

    pub async fn query(&self, sql: &str, params: &[Value]) -> DbResult<Vec<Row>> {
        let mut db = self.orm.clone();
        let rows = match &self.context {
            None => query(sql, params).exec(&mut db).await?,
            Some(ctx) => {
                let mut tx = db.transaction().await?;
                ctx.apply(&mut tx).await?;
                let rows = query(sql, params).exec(&mut tx).await?;
                tx.commit().await?;
                rows
            }
        };
        rows.into_iter().map(to_row).collect()
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

// ---------- migrations (owner role, one tokio-postgres connection) ----------

include!(concat!(env!("OUT_DIR"), "/migrations.rs"));

/// Serializes concurrent migration runs (deploy release command vs. local tasks).
const MIGRATION_LOCK: i64 = 0x5347_4d49_4752; // "SGMIGR"

async fn applied(conn: &Client) -> DbResult<Vec<String>> {
    conn.batch_execute(
        "CREATE TABLE IF NOT EXISTS _migrations (name TEXT PRIMARY KEY, applied_at BIGINT NOT NULL)",
    )
    .await?;
    Ok(conn
        .query("SELECT name FROM _migrations ORDER BY name", &[])
        .await?
        .iter()
        .map(|r| r.get(0))
        .collect())
}

/// Apply pending migrations as the table owner. Each file runs in its own transaction.
pub async fn migrate(owner_url: &str) -> DbResult<Vec<&'static str>> {
    let mut conn = crate::pg::connect(owner_url, None).await?;
    migrate_conn(&mut conn).await
}

pub async fn migrate_conn(conn: &mut Client) -> DbResult<Vec<&'static str>> {
    conn.execute("SELECT pg_advisory_lock($1)", &[&MIGRATION_LOCK])
        .await?;
    let result = async {
        let done = applied(conn).await?;
        let mut ran = Vec::new();
        for (name, sql) in MIGRATIONS {
            if done.iter().any(|d| d == name) {
                continue;
            }
            let tx = conn.transaction().await?;
            tx.batch_execute(sql).await.map_err(|e| {
                DbError::Other(format!("migration {name}: {}", crate::pg::pg_err(e)))
            })?;
            tx.execute(
                "INSERT INTO _migrations (name, applied_at) VALUES ($1, $2)",
                &[name, &chrono::Utc::now().timestamp_millis()],
            )
            .await?;
            tx.commit().await?;
            ran.push(*name);
        }
        Ok(ran)
    }
    .await;
    let _ = conn
        .execute("SELECT pg_advisory_unlock($1)", &[&MIGRATION_LOCK])
        .await;
    result
}

/// `(name, applied)` for every embedded migration.
pub async fn status(owner_url: &str) -> DbResult<Vec<(&'static str, bool)>> {
    let conn = crate::pg::connect(owner_url, None).await?;
    let done = applied(&conn).await?;
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
    let mut conn = crate::pg::connect(owner_url, None).await?;
    conn.batch_execute("DROP SCHEMA IF EXISTS public CASCADE; CREATE SCHEMA public;")
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
    fn inlines_nulls_and_renumbers() {
        let p = [Value::Int(1), Value::Null, Value::Text("x".into())];
        let (sql, kept) = inline_nulls("UPDATE t SET a=$1, b=$2, c=$3 WHERE d='$2' AND e=$3", &p);
        assert_eq!(sql, "UPDATE t SET a=$1, b=NULL, c=$2 WHERE d='$2' AND e=$2");
        assert_eq!(kept, vec![Value::Int(1), Value::Text("x".into())]);
        let (sql, _) = inline_nulls("SELECT $$ $1 $$, $1 -- $1\n", &[Value::Null]);
        assert_eq!(sql, "SELECT $$ $1 $$, NULL -- $1\n");
        let (sql, _) = inline_nulls("SELECT $1", &[Value::Int(2)]);
        assert!(matches!(sql, Cow::Borrowed(_)));
    }

    #[test]
    fn context_params() {
        let u = Uuid::nil();
        assert_eq!(Context::user(u).params()[0], u.to_string());
        assert_eq!(Context::default().params(), <[String; 5]>::default());
        assert_eq!(Context::maintenance().params()[4], "maintenance");
    }
}
