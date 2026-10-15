---
name: topcoat-toasty
description: Build, debug or review Easyshot's Rust server (server/, crate easyshot-server) with Topcoat 0.10 and Toasty 0.11 on PostgreSQL. Use for Topcoat routing, components, context, sessions, assets and formatting; Toasty models, queries, transactions and raw SQL; migrations, row-level security contexts and mise db tasks. (Toasty is sometimes misspelled toastry or tosty.)
---

# Topcoat and Toasty in Easyshot

Follow [AGENTS.md](../../../AGENTS.md) and [server/README.md](../../../server/README.md). Versions: Topcoat 0.10, Toasty 0.11 with `toasty-driver-postgresql`; check `server/Cargo.toml`/`Cargo.lock` and read the unpacked sources under `~/.cargo/registry/src/*/topcoat-*-0.10.0` and `toasty-*-0.11.0` rather than `latest` docs.

## Server shape

- One binary, one HTTP host. Topcoat serves everything (`web::router`). The legacy axum JSON API (`src/routes/*`) is mounted unchanged through `TowerRoute` at `/v1/{*rest}`, `/s/{slug}` and `/healthz`. New JSON endpoints for the Mac app and agents go in `src/routes/*`; web pages and their form/SSE endpoints in `src/web/*` (`watch`, `account`, `layout`, `assets`).
- Video domain: `src/video/` — `model` (Toasty models), `scope` (who may see/manage what; produces the RLS context), `service` (use cases), `live` (change fan-out), `limit` (rate limits).
- Shared state: `AppState` registered with `.app_context(state)`; read it via `web::state(cx)`.
- Topcoat's reactive runtime, shards and procedures are not used; Datastar owns client DOM ([datastar skill](../datastar/SKILL.md)).

## Database rules

- **PostgreSQL only; Toasty is the single DB library.** Consolidation from sqlx is the decided direction (in progress on another branch at the time of writing): new code uses Toasty models, or `toasty::sql::statement`/`toasty::sql::query` (Postgres `$n` placeholders) for upserts, aggregates, `ON CONFLICT` or `FOR UPDATE`. Never add sqlx. The only other Postgres access is `tokio-postgres` single connections for migrations and `LISTEN`.
- **Every unit of work is one Toasty transaction opened by `orm::begin(&mut db, &ctx)`**, which installs the RLS `Context` with `set_config(..., true)` on that transaction's connection. Commit explicitly; dropping rolls back. Do not run owned-table queries on the bare `Db` (they read as empty under RLS).
- **Row-level security.** The app connects as `easyshot_app` (`NOSUPERUSER NOBYPASSRLS`). Owned tables (screenshots, videos, `item_*`) have FORCEd policies on `app.user_id` / `app.workspace_id`. `Context` also carries `share_slug`/`share_item_id` (the single marked share-link bypass) and `maintenance` (retention and purge only). Pre-auth tables — users, sessions, auth_codes, api_tokens, login_attempts — have no policy; every query on them filters by an explicit id, email or token hash.
- **Filter explicitly anyway.** Access decisions go through `video::scope::Scope` (`managed`, `items`, `context()`); RLS is the second wall, not the filter.
- **Schema.** `server/migrations/*.sql` owns every table, including Toasty-mapped ones; Toasty never pushes or migrates. Create files with `mise run db:new -- name`; apply as the owner with `mise run db:migrate` (the binary's `migrate up|status|reset --yes`). Follow existing conventions: UUID text ids, epoch-millisecond `BIGINT` timestamps, no foreign keys (the app deletes children), nullable `workspace_id` on item tables, FORCEd RLS with policies for new owned tables, grants for the app role. Every new owned table needs an RLS test in `tests/rls.rs`.
- **Models** map existing tables with `#[table = "…"]`, `#[key]`, `#[index]`, `#[unique]`; register them in `video::model::models()` (or the equivalent set) and keep field types to what the driver maps cleanly (`String`, `i64`, `Option<…>`).

## Topcoat rules

- Handlers: `#[page("/path")]` for GET pages, `#[route(POST "/path")]` for mutations; register each in `web::router` (explicit registration, not module routing). Read path params with `path_param`, queries with `query_params`, forms with `Form<T>`.
- Components: `#[component] async fn … -> Result<impl View>`, `view!` with literal text in quotes and `(value)` interpolation (escaped). Do writes before building views; rendering is lazy and concurrent.
- Sessions: Topcoat cookie sessions (`CookieTokenStore`), persisted as token hashes in the shared `sessions` table; `web::member(cx)` resolves the signed-in member. Set cookies before the response streams.
- Security: origin checks for mutations, CSP in `web::csp` (`'unsafe-eval'` approved for Datastar; nothing inline), rate limits in `video::limit`.

Patterns and pitfalls: [Topcoat](references/topcoat.md), [Toasty](references/toasty.md).

## Verify

`mise run db:test:reset && mise run server:test` (one throwaway schema per test, code under test connected as the app role), `cargo clippy --all-targets -- -D warnings`, `cargo fmt --check`, `topcoat fmt --check` (rustfmt does not format macro bodies). Local Postgres: `postgres:postgres@localhost:5432`, databases `easyshot_dev`/`easyshot_test` via `mise run db:create`/`db:test`. UI changes also need a browser check; report what you ran.
