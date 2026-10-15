//! Production database setup: `easyshot-server db bootstrap|verify`.
//!
//! `bootstrap` has two modes, both safe to rerun:
//! - Provider login (`DATABASE_URL`, the preferred mode; PlanetScale): the login was created
//!   with `pscale role create` and has no inherited roles. Migrations run (as `MIGRATION_ROLE`
//!   when set), then `easyshot_grant_app_login` makes the login a member of the
//!   `easyshot_app` privilege role and removes easyshot_app's own login. Rotate by creating a
//!   new login and running bootstrap with its URL.
//! - Password (`APP_DATABASE_PASSWORD`), for providers without managed logins: creates the
//!   `easyshot_app` login with that password, or rotates it, then migrates.
//!
//! `verify` (owner and app URLs) checks that the server's login has easyshot_app's
//! privileges, cannot bypass row-level security, is not an admin and does not own the
//! tables, does not use the development password, and that every migration is applied and
//! every owner-scoped table has a FORCE'd policy.

use crate::db::{self, DbError, DbResult};
use crate::pg;

pub const APP_ROLE: &str = "easyshot_app";
/// Tables whose rows belong to an owner and must be guarded by a FORCE'd policy.
pub const RLS_TABLES: [&str; 6] = [
    "screenshots",
    "videos",
    "item_comments",
    "item_reactions",
    "item_views",
    "upload_parts",
];

/// How the server signs in.
pub enum AppLogin<'a> {
    /// A provider-managed login; the app URL's user is granted easyshot_app.
    Provider { app_url: &'a str },
    /// easyshot_app itself, with this password.
    Password(&'a str),
}

pub async fn bootstrap(owner_url: &str, login: AppLogin<'_>) -> DbResult<Vec<String>> {
    match login {
        AppLogin::Provider { app_url } => bootstrap_provider(owner_url, app_url).await,
        AppLogin::Password(password) => bootstrap_password(owner_url, password).await,
    }
}

async fn bootstrap_provider(owner_url: &str, app_url: &str) -> DbResult<Vec<String>> {
    let user = pg::url_user(app_url)
        .ok_or_else(|| DbError::Other("DATABASE_URL has no user name".into()))?;
    let mut out: Vec<String> = db::migrate(owner_url)
        .await?
        .into_iter()
        .map(|n| format!("applied {n}"))
        .collect();
    // Explicitly as well: 0007 may already be applied (a rotated login).
    let conn = db::owner_session(owner_url).await?;
    let role: String = conn
        .query_one("SELECT easyshot_grant_app_login($1, true)", &[&user])
        .await?
        .get(0);
    out.push(format!(
        "granted {APP_ROLE} to login {role}; {APP_ROLE} itself cannot log in"
    ));
    out.push("migrations up to date".into());
    Ok(out)
}

async fn bootstrap_password(owner_url: &str, app_password: &str) -> DbResult<Vec<String>> {
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
            "SELECT current_user::text, r.rolsuper, r.rolbypassrls, current_schema()::text, \
                    pg_has_role(current_user, 'easyshot_app', 'USAGE'), \
                    EXISTS (SELECT 1 FROM pg_roles a WHERE a.rolname IN ('postgres', 'pg_write_all_data') \
                            AND pg_has_role(current_user, a.oid, 'MEMBER')) \
             FROM pg_roles r WHERE r.rolname = current_user",
            &[],
        )
        .await?;
    let (user, superuser, bypass, schema, has_app, admin): (
        String,
        bool,
        bool,
        String,
        bool,
        bool,
    ) = (
        row.get(0),
        row.get(1),
        row.get(2),
        row.get(3),
        row.get(4),
        row.get(5),
    );
    checks.push((
        format!("app login {user} has {APP_ROLE}'s privileges"),
        has_app,
    ));
    checks.push((
        "app login inherits no admin or write-all role".into(),
        !admin,
    ));
    checks.push(("app role is not a superuser".into(), !superuser));
    checks.push(("app role cannot bypass row-level security".into(), !bypass));
    // USAGE follows inherited privileges; SET also finds roles reachable only through
    // SET ROLE (including recursive memberships with INHERIT FALSE).
    let reachable =
        "(pg_has_role(current_user, r.oid, 'USAGE') OR pg_has_role(current_user, r.oid, 'SET'))";
    let elevated: i64 = app
        .query_one(
            &format!(
                "SELECT count(*) FROM pg_roles r WHERE {reachable} AND \
         (r.rolsuper OR r.rolbypassrls OR r.rolcreaterole OR r.rolcreatedb OR r.rolreplication \
          OR r.rolname IN ('pg_read_all_data', 'pg_write_all_data', 'pg_read_server_files', \
                          'pg_write_server_files', 'pg_execute_server_program'))"
            ),
            &[],
        )
        .await?
        .get(0);
    checks.push((
        "app login cannot inherit or SET ROLE to an elevated role".into(),
        elevated == 0,
    ));
    let owned: i64 = app
        .query_one(
            &format!(
                "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace \
         JOIN pg_roles r ON r.oid = c.relowner WHERE n.nspname = $1 AND {reachable}"
            ),
            &[&schema],
        )
        .await?
        .get(0);
    checks.push(("app role owns no tables".into(), owned == 0));
    let schema_owner: bool = app
        .query_one(
            &format!(
                "SELECT EXISTS (SELECT 1 FROM pg_namespace n JOIN pg_roles r ON r.oid = n.nspowner \
         WHERE n.nspname = $1 AND {reachable})"
            ),
            &[&schema],
        )
        .await?
        .get(0);
    checks.push((
        "app login cannot assume the schema owner".into(),
        !schema_owner,
    ));
    let definers: i64 = app.query_one(
        "SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace \
         WHERE n.nspname = $1 AND p.prosecdef AND has_function_privilege(current_user, p.oid, 'EXECUTE')",
        &[&schema]).await?.get(0);
    checks.push((
        "app login cannot execute schema SECURITY DEFINER functions".into(),
        definers == 0,
    ));
    let grant_callable: bool = app.query_one(
        "SELECT COALESCE(has_function_privilege(current_user, to_regprocedure('easyshot_grant_app_login(text,boolean)'), 'EXECUTE'), false)",
        &[]).await?.get(0);
    checks.push((
        "app login cannot execute the role grant helper".into(),
        !grant_callable,
    ));
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
