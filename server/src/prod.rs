//! Production database setup: `easyshot-server db bootstrap|verify`.
//!
//! `bootstrap` (owner URL + `APP_DATABASE_PASSWORD`) creates the `easyshot_app` role with
//! that password, or rotates it, grants it connect, then runs migrations, which add the
//! table grants and policies. Rerunning it is safe. `verify` (owner and app URLs) checks
//! that the server's role cannot bypass row-level security, does not own the tables, does
//! not use the development password, and that every migration is applied and every
//! owner-scoped table has a FORCE'd policy.

use crate::db::{self, DbError, DbResult};
use crate::pg;

pub const APP_ROLE: &str = "easyshot_app";
/// Tables whose rows belong to an owner and must be guarded by a FORCE'd policy.
pub const RLS_TABLES: [&str; 5] = [
    "screenshots",
    "videos",
    "item_comments",
    "item_reactions",
    "item_views",
];

pub async fn bootstrap(owner_url: &str, app_password: &str) -> DbResult<Vec<String>> {
    if app_password.len() < 16 || app_password == APP_ROLE {
        return Err(DbError::Other(
            "APP_DATABASE_PASSWORD must be at least 16 characters and not the dev default".into(),
        ));
    }
    let conn = pg::connect(owner_url, None).await?;
    let exists = conn
        .query_opt("SELECT 1 FROM pg_roles WHERE rolname = $1", &[&APP_ROLE])
        .await?
        .is_some();
    let verb = if exists { "ALTER" } else { "CREATE" };
    let attrs = "LOGIN NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE NOINHERIT";
    // DDL cannot take parameters; quote the password server-side.
    let sql: String = conn
        .query_one(
            &format!("SELECT format('{verb} ROLE {APP_ROLE} {attrs} PASSWORD %L', $1::text)"),
            &[&app_password],
        )
        .await?
        .get(0);
    conn.batch_execute(&sql).await?;
    conn.batch_execute(&format!(
        "DO $$ BEGIN EXECUTE format('GRANT CONNECT ON DATABASE %I TO {APP_ROLE}', current_database()); END $$"
    ))
    .await?;
    let mut out = vec![format!(
        "{} role {APP_ROLE}",
        if exists {
            "rotated password of"
        } else {
            "created"
        }
    )];
    drop(conn);
    for name in db::migrate(owner_url).await? {
        out.push(format!("applied {name}"));
    }
    out.push("migrations up to date".into());
    Ok(out)
}

/// One check: description and whether it passed.
pub type Check = (String, bool);

pub async fn verify(owner_url: &str, app_url: &str) -> DbResult<Vec<Check>> {
    let mut checks = Vec::new();
    let app = pg::connect(app_url, None).await?;
    let row = app
        .query_one(
            "SELECT current_user::text, r.rolsuper, r.rolbypassrls, current_schema()::text \
             FROM pg_roles r WHERE r.rolname = current_user",
            &[],
        )
        .await?;
    let (user, superuser, bypass, schema): (String, bool, bool, String) =
        (row.get(0), row.get(1), row.get(2), row.get(3));
    checks.push((format!("app URL connects as {user}"), user == APP_ROLE));
    checks.push(("app role is not a superuser".into(), !superuser));
    checks.push(("app role cannot bypass row-level security".into(), !bypass));
    let owned: i64 = app
        .query_one(
            "SELECT count(*) FROM pg_tables WHERE schemaname = $1 AND tableowner = current_user",
            &[&schema],
        )
        .await?
        .get(0);
    checks.push(("app role owns no tables".into(), owned == 0));
    let dev_password = app_url
        .trim()
        .parse::<tokio_postgres::Config>()
        .ok()
        .and_then(|c| c.get_password().map(|p| p == APP_ROLE.as_bytes()))
        .unwrap_or(false);
    checks.push((
        "app role does not use the development password".into(),
        !dev_password,
    ));
    drop(app);

    let pending: Vec<_> = db::status(owner_url)
        .await?
        .into_iter()
        .filter(|(_, applied)| !applied)
        .map(|(n, _)| n)
        .collect();
    checks.push((
        if pending.is_empty() {
            "all migrations applied".into()
        } else {
            format!("pending migrations: {}", pending.join(", "))
        },
        pending.is_empty(),
    ));
    let owner = pg::connect(owner_url, None).await?;
    for table in RLS_TABLES {
        let forced = owner
            .query_opt(
                "SELECT c.relrowsecurity AND c.relforcerowsecurity \
                   AND EXISTS (SELECT 1 FROM pg_policy p WHERE p.polrelid = c.oid) \
                 FROM pg_class c WHERE c.oid = to_regclass($1)",
                &[&table],
            )
            .await?
            .map(|r| r.get::<_, bool>(0))
            .unwrap_or(false);
        checks.push((
            format!("{table}: row-level security enabled and FORCE'd"),
            forced,
        ));
    }
    Ok(checks)
}
