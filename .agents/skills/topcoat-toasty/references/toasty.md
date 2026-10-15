# Toasty persistence in Easyshot (0.11, PostgreSQL)

Baseline: Toasty 0.11.0 with `toasty-driver-postgresql`, pinned in `server/Cargo.lock`. Read generated methods and the crate source instead of guessing names from other ORMs. Guide: [Toasty 0.11](https://tokio-rs.github.io/toasty/0.11.0/guide/introduction.html).

## Handle and pool

- One Toasty `Db` pool per process, built in `orm::connect` with `.models(…)`, `.max_pool_size(…)` and the Postgres driver, connected as the app role (`DATABASE_URL`). Get a handle with `st.orm()`; clones share the pool. Do not reconnect per request or wrap the pool in a global mutex.
- Migrations and the live `LISTEN` use dedicated `tokio-postgres` connections (owner role for migrations), never a second pool.

## Transactions with RLS

```rust
let mut db = st.orm().await?;
let mut tx = orm::begin(&mut db, &scope.context()).await?;   // set_config(..., true) first
let v = Video::filter_by_slug(slug).first().exec(&mut tx).await.map_err(orm_err)?;
// ... more reads/writes through &mut tx ...
tx.commit().await.map_err(orm_err)?;
```

- Route every operation of a unit of work through that transaction; a cloned `Db` runs outside it (and outside the RLS context).
- Keep transactions short; never hold one across an SSE stream or an external call (S3, mail).
- `orm_err` maps errors to `AppError`; `is_unique_violation` detects SQLSTATE 23505 (used for slug retries).

## Models

```rust
#[derive(Debug, Clone, toasty::Model)]
#[table = "videos"]
pub struct Video { #[key] pub id: String, #[index] pub user_id: String, #[unique] pub slug: String, /* … */ }
```

- Models map tables created by migrations; Toasty never creates or alters schema (no `push_schema`, no Toasty migrations).
- Generated API in use: `toasty::create!(Video { … }).exec(&mut tx)`, `Video::filter_by_id(id).first()`, `Video::filter_by_user_id(…)`, `Video::update_by_id(id).title(…).updated_at(…)`, `.exec(&mut tx)`.
- Keep field types to `String`, `i64`, `Option<…>`, matching the TEXT/BIGINT conventions.

## Raw SQL

For what the query builder does not express (upserts with `ON CONFLICT`, counts and grouped aggregates, `FOR UPDATE`, set-based deletes):

```rust
let rows = toasty::sql::query("SELECT emoji, count(*) FROM item_reactions WHERE item_id = $1 GROUP BY emoji")
    .bind(item_id.as_str())
    .exec(&mut tx).await.map_err(orm_err)?;   // dynamic Value records, selected-column order
toasty::sql::statement("INSERT INTO item_views (…) VALUES ($1, …) ON CONFLICT DO NOTHING")
    .bind(…).exec(&mut tx).await.map_err(orm_err)?;  // affected-row count
```

Raw SQL is Postgres SQL with `$n` placeholders; Toasty does not rewrite it or hydrate models from it. Bind values; never format user input into SQL. Use `Query::column_types` when a result type is ambiguous.

## Reads

- Bound and order list queries explicitly. Cursor pagination needs a total order (e.g. `created_at DESC, id DESC`); a short page is not proof of the last page.
- Load what a list renders in one query or a few batched ones; look for queries inside loops (N+1). Topcoat's concurrent rendering does not remove round-trips.

## Writes

- Parse form/JSON input into explicit input types, validate, and list the fields written. Derive owner, workspace and visibility rules from the server-side `Scope`, never from input.
- Do writes in the handler/service before rendering. Publish live changes after commit.
- Let database constraints be the final word on uniqueness.

## Schema evolution

`mise run db:new -- name` creates a timestamped file in `server/migrations/` (existing files are `000N_…`; name order still applies). Write portable, idempotent DDL in the existing style, add RLS policies and grants for new owned tables, run `mise run db:migrate` and `mise run db:test:reset`, and add tests. Never edit an applied migration that production has run; in dev, rebuild with `mise run db:reset`.
