# Toasty persistence with Topcoat

Baseline: Toasty 0.11.0, researched 2026-10-14. Confirm the target project's pinned version and database driver before adapting API names. Topcoat's request-context examples sometimes use illustrative database methods; the Toasty guide and rustdoc define the ORM APIs.

## Database lifetime and models

Define Rust structs with `#[derive(toasty::Model)]`; declare keys, generated values, uniqueness, and indexes through model attributes. The derive generates query and mutation builders. Register models with `Db::builder().models(toasty::models!(...))`, including models in separate crates as appropriate. Use the feature flag matching the connection URL and selected backend. SQL and NoSQL support differ; verify backend-specific operations.

Create the database pool at startup and register the `Db` as Topcoat app context. Clone the handle for mutable query/transaction execution where required by the installed release. Clones share a pool; do not reconnect or protect the whole database with a global mutex for each request. Configure pool bounds and wait/connection timeouts according to the service's workload.

Sources: [model introduction](https://tokio-rs.github.io/toasty/0.11.0/guide/introduction.html), [database setup and pooling](https://tokio-rs.github.io/toasty/0.11.0/guide/database-setup.html), [handle cloning and executors](https://tokio-rs.github.io/toasty/0.11.0/guide/transactions.html).

## Reads and relationships

Inspect generated methods instead of guessing names from another ORM. In this release, `toasty::create!(Model { ... }).exec(&mut db).await?` inserts a model, and generated lookup methods accept an executor and key. Import traits required by the installed release's examples.

Bound list queries and sort explicitly. Cursor pagination requires ordering; use returned cursors to continue through tied sort values. A short page need not be the last page: use `.has_next()` or `.next()` rather than inferring completion from its length. Offset pagination requires a limit and becomes more expensive at large offsets.

Preload relations needed by a list with `.include(Model::fields().relation())`. An awaited association accessor issues a query; a loaded `Deferred` relation's `.get()` reads memory. Look for relation awaits inside loops to catch N+1 behavior. Topcoat's concurrent component rendering does not eliminate database round-trips.

Sources: [getting started API shapes](https://tokio-rs.github.io/toasty/0.11.0/guide/getting-started.html), [pagination](https://tokio-rs.github.io/toasty/0.11.0/guide/sorting-limits-and-pagination.html), [preloading](https://tokio-rs.github.io/toasty/0.11.0/guide/preloading-associations.html).

## Mutation boundaries

These are application integration recommendations: authorize against the authenticated user and scope reads/writes to permitted records; neither a model derive nor a typed ID proves access. Parse form input into an explicit input type, validate it, and list allowed model fields in the mutation. Derive owner, tenant, and privilege fields from server-side facts. Preserve database constraints as the final enforcement of uniqueness and related invariants.

Perform writes in a handler/procedure/application operation before constructing response markup. Avoid mutations embedded in render expressions or components whose execution order is unspecified. Return a form error, redirect, or partial update appropriate to the existing interaction model.

Do not assume automatic safe form-to-model binding exists. Check the installed release: the Topcoat documentation's roadmap calls out improved Toasty form integration as future work. [Topcoat roadmap](https://docs.rs/topcoat/0.10.0/topcoat/#roadmap)

## Atomic operations

Use an interactive transaction when atomic work must branch on reads. Route every operation belonging to that transaction through its mutable transaction executor, then commit. Dropping an uncommitted transaction rolls it back. A cloned database handle executes outside that transaction, so do not use one for a step that belongs inside it.

Consider a batch for independent operations needing atomic execution, after checking backend support. Select isolation and savepoint behavior for the actual database and concurrency requirement; do not infer identical support across drivers. Verify rollback with an induced failure for multi-step mutations.

Source: [transactions and backend limits](https://tokio-rs.github.io/toasty/0.11.0/guide/transactions.html).

## Schema evolution

`push_schema` is useful for fresh prototypes/tests; it pushes the full schema and does not track changes. For existing data, use the migration system supported by the installed release.

Toasty 0.11 provides `toasty-cli` as a library for a project-specific CLI that can load the application's models. Do not assume a globally installed CLI knows those models. Preserve an existing CLI's command structure.

After editing models, generate a migration, review SQL and rename detection, apply to an isolated database, and commit SQL, snapshots, and history together. Ensure generation targets the intended driver. A rename accidentally represented as drop-and-create may destroy data. Do not use reset to upgrade a populated database, or edit applied history to conceal a schema mismatch. Dropping a migration from files/history does not undo an already-applied database change.

Source: [schema management](https://tokio-rs.github.io/toasty/0.11.0/guide/schema-management.html).
