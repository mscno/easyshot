# Shotglass server

Rust backend and web presence for Shotglass: accounts, presigned screenshot uploads with short share links (`/s/{slug}[.ext]`), Loom-style video sharing (instant links, a watch page with timestamped comments, reactions and transcripts), retention, and automatic removal of accounts inactive for 90 days. PostgreSQL only. Billing is not implemented; `users.plan` exists for later.

Media bytes never pass through the server: clients PUT straight to presigned URLs (screenshots as one object, recordings as S3 multipart parts streamed while recording), and viewers are redirected to short-lived presigned GETs.

## Architecture

- **One binary, one HTTP host.** Topcoat (0.10) serves every request. The JSON API is an axum `Router` (`src/routes`) mounted unchanged through `TowerRoute` at `/v1/{*rest}`, `/s/{slug}` and `/healthz`; web pages are Topcoat handlers in `src/web`. The `lambda` feature still builds the API-only axum router for AWS Lambda; the web pages need the container (Fly) deploy.
- **Data access.** Users, sessions, auth codes, API tokens and screenshots stay in the sqlx repository layer (`src/repo.rs`, `src/db.rs`); porting them to Toasty would not change behaviour. The video domain (`videos`, `item_comments`, `item_reactions`, `item_views`) uses Toasty 0.11 models (`src/video/model.rs`) over Toasty's PostgreSQL driver. Both pools connect as the app role.
- **Schema ownership.** `migrations/*.sql` owns every table, including those Toasty maps; Toasty never creates or alters schema. Files are embedded at build time (`build.rs`), applied in name order as the owner role inside one transaction each, under an advisory lock, and recorded in `_migrations`. New migrations: `mise run db:new -- name` (timestamped).
- **Team-ready, without teams.** Every video-domain table has a nullable `workspace_id`; conversation tables reference a generic `item_id` and `videos` has a `kind`, so videos can later merge with screenshots into one `items` table with child assets; `visibility` is an application enum (`link`, `password`, `private`) stored without a CHECK constraint so it can gain `workspace`; all access decisions go through one scope helper (`src/video/scope.rs`).
- **Live updates.** Each watch page holds one Datastar SSE stream (`/v/{slug}/live`). Writes publish a change to an in-process hub; the stream re-renders the affected region and patches it by id. A 20 s resync covers changes made on other instances and keeps view counts fresh; streams close while the tab is hidden.
- **Browser runtime.** One self-hosted bundle, `static/datastar-rocket-1.0.4.js` (Datastar v1.0.4 + Rocket beta.2, MIT, `static/DATASTAR-LICENSE.md`, sha256 `c723fb309157a555609df273e4693dcc4e193e68e6d7477f3285b955288e1e7b`), loaded once by the layout and imported by `static/app.js` from the same URL. Topcoat's own reactive runtime is not enabled. `<shotglass-player>` is a light-DOM Rocket component over a native `<video controls>`, which also works without JavaScript. Forms are native posts that Datastar enhances (form encoding, retries off). Assets are compiled into the binary and cached immutably.

## Database roles and row-level security

Migrations run as the table owner (`MIGRATION_DATABASE_URL`, or `--database-url`). The server connects as `shotglass_app` (`DATABASE_URL`), created by migration `0004_rls_app_role` with `NOSUPERUSER NOBYPASSRLS`. In production, create the role beforehand with its own password; the migration then only grants. A superuser or `BYPASSRLS` connection defeats RLS.

`screenshots`, `videos` and the `item_*` tables have `FORCE`d policies keyed on transaction-local settings, set with `set_config(..., true)` as the first statement of every transaction:

| Setting | Grants |
|---|---|
| `app.user_id` | the owner's rows (and their items' conversation) |
| `app.workspace_id` | reserved: items of that workspace |
| `app.share_slug` | read-only access to the one item with that slug (public share-link path) |
| `app.share_item_id` | with the matching slug: read and insert that item's comments, reactions and views |
| `app.rls_bypass = 'maintenance'` | everything; retention and account purge only (`Context::maintenance`) |

sqlx code applies a `db::Context` per statement (`Db::scoped`); Toasty work runs inside `orm::begin`, which opens a Toasty transaction and runs the `set_config` through `toasty::sql` on that connection. Without a context, owner-scoped tables read as empty. `users`, `sessions`, `auth_codes`, `api_tokens` and `login_attempts` have no policy on purpose: they are read before a principal is known and every query filters by an explicit user id, email or token hash. `tests/rls.rs` runs unfiltered SQL as the app role to show the database itself denies cross-owner, cross-workspace and out-of-share reads and writes, including inside Toasty transactions.

## Local setup

Requires PostgreSQL 18 on `localhost:5433` (user/password `postgres`), [mise](https://mise.jdx.dev) and Docker for MinIO. Tasks live in the repository's `mise.toml`:

```sh
docker compose up -d minio minio-init     # MinIO :9000 (console :9001), bucket `shotglass`
mise run db:create                         # shotglass_dev
mise run db:migrate                        # as the owner; creates shotglass_app
mise run db:seed                           # dev@shotglass.test / teammate@shotglass.test
mise run server:dev                        # http://127.0.0.1:8080, app role, MinIO
```

`db:status`, `db:reset` (dev only: drops and rebuilds `public`), `db:new -- name`, `db:test` and `db:test:reset` work the same way. Override `DEV_DATABASE_URL`, `TEST_DATABASE_URL` or `DEV_APP_DATABASE_URL` in `mise.local.toml`. Without Lettermint, web sign-in codes cannot be mailed; the API (`/v1/auth/login`) still works with the seeded password `shotglass-dev-password`.

Tests run against `TEST_DATABASE_URL` (default `shotglass_test` on :5433), one throwaway schema per test, migrated as the owner, with the code under test connected as `shotglass_app`:

```sh
mise run server:test                       # or: cd server && cargo test
cargo clippy --all-targets -- -D warnings
cargo fmt --check && topcoat fmt --check src/web/*.rs   # cargo install topcoat-cli
```

Whole stack in containers: `docker compose --profile postgres --profile app up --build`.

The binary's own commands: `shotglass-server [serve]`, `migrate up|status|reset --yes`, `seed` (owner URL via `--database-url` or `MIGRATION_DATABASE_URL`).

## Web pages

| Path | Page |
|---|---|
| `/` | Landing page; download link from `DOWNLOAD_URL` |
| `/v/{slug}` | Watch page: player, transcript (from the WebVTT track; click a line to seek), timestamped comments (guests name themselves and are labelled guests; members come from the session), emoji reactions, view count, copy link, download. Shows "Still uploading" until the upload completes, then swaps in the player live. Password videos show a gate; private and expired ones are 404. Open Graph, Twitter player and oEmbed discovery tags for link-visible videos. |
| `/v/{slug}/embed` | Player only, frameable (oEmbed `html`) |
| `/v/{slug}/media`, `/download`, `/thumbnail.jpg` | 302 to presigned GETs (6 h, 10 min, 10 min) after the access check |
| `/v/{slug}/transcript.vtt` | The transcript, same origin so `<track>` needs no bucket CORS |
| `/v/{slug}/live` | Datastar SSE stream |
| `POST /v/{slug}/comments`, `/reactions`, `/unlock` | Native forms; Datastar gets SSE patches, plain posts a 303 |
| `/oembed?url=` | oEmbed JSON for link-visible, ready videos |
| `/login`, `POST /login`, `POST /login/verify`, `POST /logout` | Email-code sign-in for existing accounts (accounts are created in the app); the session is a `__Host-sg_session` cookie whose token hash is stored in `sessions` |
| `/library` | The owner's videos: rename, visibility (link / password / only me), send to an email address (Lettermint, 20 per hour), delete |

Security: Topcoat's origin policy rejects cross-site state-changing browser requests; the CSP allows scripts and styles only from `'self'` (plus `'unsafe-eval'`, which Datastar needs to compile `data-*` expressions), media and images from `https:` (and a plain-HTTP dev store); comment, reaction, unlock and sign-in posts are rate limited per client address or user; password unlocks are an HMAC cookie bound to the current password hash; views are counted once per viewer per UTC day using a keyed hash of day, address and user agent.

## Video upload API

Auth as for screenshots (`Authorization: Bearer ...`; uploads need a confirmed email when `REQUIRE_EMAIL_VERIFICATION=true`). The share link exists before any bytes are uploaded.

| Endpoint | Body | Result |
|---|---|---|
| `POST /v1/videos` | `{title?, content_type?}` (`video/mp4` default, `video/quicktime`, `video/webm`) | 201 video JSON with `share_url` and `upload: {min_part_bytes, max_bytes, max_part_batch, part_url_ttl_seconds}` |
| `POST /v1/videos/{id}/parts` | `{part_numbers: [1, 2, ...]}` (≤ 100 per call, 1..=10000) | `{parts: [{part_number, method: "PUT", url}], expires_in}`; PUT the bytes and keep each `ETag` |
| `POST /v1/videos/{id}/complete` | `{parts: [{part_number, etag}], duration_ms?, width?, height?}` | video JSON (`status: ready`); idempotent |
| `POST /v1/videos/{id}/thumbnail` | `{byte_size}` (JPEG, ≤ 2 MiB) | `{upload: {method, url, headers}}` |
| `POST /v1/videos/{id}/transcript` | `{byte_size}` (WebVTT, ≤ 1 MiB) | `{upload: {method, url, headers}}` |
| `GET /v1/videos`, `GET /v1/videos/{id}` | | the caller's videos |
| `PATCH /v1/videos/{id}` | `{title?, visibility?, password?}` | video JSON |
| `DELETE /v1/videos/{id}` | | 204; aborts the upload, deletes objects and conversation |

Every part except the last must be at least 5 MiB (S3 rule). Upload parts while recording and complete on stop; the watch page flips to the player within a moment. Oversized results (`MAX_VIDEO_BYTES`) are deleted at completion (413).

## Deploy (Fly.io + PostgreSQL)

Production is PostgreSQL, e.g. Fly Managed Postgres or Neon, with two connection strings: the owner (`MIGRATION_DATABASE_URL`) and `shotglass_app` (`DATABASE_URL`). Once per database, as the owner: `CREATE ROLE shotglass_app LOGIN NOSUPERUSER NOBYPASSRLS NOINHERIT PASSWORD '...'` (Neon: the `*_owner` role can create it; Fly MPG: the provided owner user). `fly.toml` runs `shotglass-server migrate up` as the release command, so migrations apply as the owner before new machines start; the app itself never needs the owner URL. Use the pooled endpoint for `DATABASE_URL` only if it is a session pooler: transaction-mode pooling breaks prepared statements and transaction-local settings stay safe only within a transaction.

The machine can scale to zero: startup only parses config. Create the bucket with `fly storage create` (Tigris); it sets `BUCKET_NAME`, `AWS_REGION=auto`, `AWS_ENDPOINT_URL_S3`, `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`, which the server uses as-is (presigned URLs are virtual-hosted style, region `auto`). Do not set `S3_FORCE_PATH_STYLE`. Secrets: `DATABASE_URL`, `MIGRATION_DATABASE_URL`, `CRON_SECRET`, `PUBLIC_BASE_URL`, `WEB_SECRET` (synced from GitHub secrets by `.github/workflows/deploy-server.yml`). `TRUSTED_PROXY_HOPS=1` makes client addresses come from Fly's proxy. Trigger `POST /v1/internal/expire` from an external scheduler, since a scaled-to-zero machine cannot run its own timer. Live streams are per instance with a 20 s cross-instance resync, so more than one machine works without extra infrastructure.

Moving existing data off Turso is a one-off export/import of `users`, `sessions`, `api_tokens`, `auth_codes` and `screenshots` (same columns) before switching `DATABASE_URL`.

## Environment variables

| Var | Default | Notes |
|---|---|---|
| `DATABASE_URL` | required | app role (`shotglass_app`), `postgres://` |
| `MIGRATION_DATABASE_URL` | unset | owner role; used by `migrate`, and at startup when `RUN_MIGRATIONS=true` |
| `RUN_MIGRATIONS` | `false` | apply migrations at startup (needs `MIGRATION_DATABASE_URL`) |
| `DB_MAX_CONNECTIONS` | `5` | per pool (sqlx and Toasty each); lazy, 5 s acquire timeout |
| `S3_BUCKET` | required | falls back to `BUCKET_NAME` |
| `BIND_ADDR` | `0.0.0.0:8080` | ignored on Lambda |
| `PUBLIC_BASE_URL` | `http://localhost:8080` | used for share links, oEmbed and Open Graph URLs |
| `S3_REGION` | `us-east-1` | falls back to `AWS_REGION` |
| `S3_ENDPOINT` | unset | custom endpoint (MinIO, R2); otherwise the SDK honors `AWS_ENDPOINT_URL_S3` |
| `S3_FORCE_PATH_STYLE` | `false` | `true` for MinIO |
| AWS creds | | standard aws-config chain (env, profile, IAM role) |
| `CRON_SECRET` | unset | enables `POST /v1/internal/expire`; 404 when unset |
| `RETENTION_DAYS` | `30` | screenshots |
| `VIDEO_RETENTION_DAYS` | `90` | videos |
| `INACTIVE_USER_DAYS` | `90` | purge users not seen for this long; `0` disables |
| `MAX_UPLOAD_BYTES` | `26214400` | screenshots |
| `MAX_VIDEO_BYTES` | `5368709120` | videos |
| `WEB_SECRET` | random per process | keys unlock cookies and viewer hashes; set it in production so they survive restarts and agree across machines |
| `TRUSTED_PROXY_HOPS` | `0` | reverse proxies that set `X-Forwarded-For` (1 on Fly) |
| `DOWNLOAD_URL` | GitHub latest release | landing-page download button |
| `ALLOW_SIGNUPS` | `true` | |
| `LETTERMINT_API_TOKEN` | unset | Lettermint project token (`lm_...`). Enables email (codes, web sign-in, "send to"); when unset the code endpoints answer 503 |
| `MAIL_FROM` | unset | `Name <sender@verified-domain>`; required with the token |
| `LETTERMINT_ROUTE` | `transactional` | Lettermint route |
| `LETTERMINT_API_URL` | `https://api.lettermint.co/v1` | override for testing |
| `REQUIRE_EMAIL_VERIFICATION` | `true` when the token is set, else `false` | creating uploads needs a confirmed email |
| `AUTH_CODE_TTL_MINUTES` | `10` | lifetime of emailed codes |
| `RUST_LOG` | `info` | JSON logs |

## Deploy to AWS Lambda (cargo-lambda)

Lambda serves the JSON API only (no web pages, no live streams).

```sh
cargo install cargo-lambda
cargo lambda build --release --features lambda --arm64
cargo lambda deploy shotglass-server --enable-function-url   # or put behind API Gateway HTTP API
```

Set the env vars above on the function and run migrations separately (`shotglass-server migrate up` with the owner URL). Grant the execution role `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject`, `s3:AbortMultipartUpload` on `arn:aws:s3:::BUCKET/*` and `s3:ListBucket` on the bucket (HEAD of a missing key returns 404 rather than 403 only with ListBucket). Presigned URLs are signed with the role's credentials, so they expire with the role session. If you use an API Gateway stage path, set `AWS_LAMBDA_HTTP_IGNORE_STAGE_IN_PATH=true`. Use a Postgres reachable from Lambda (RDS Proxy in session mode / Neon; keep `DB_MAX_CONNECTIONS` small). Argon2id uses ~19 MiB per hash, so give the function at least 512 MB.

## Container

```sh
docker build -t shotglass-server .
docker run --env-file .env -p 8080:8080 shotglass-server
```

## Expiry

Screenshots expire `RETENTION_DAYS` and videos `VIDEO_RETENTION_DAYS` after creation. Two layers:

1. **S3 lifecycle rule (backstop)**: expire all objects at 31 days.
   ```sh
   aws s3api put-bucket-lifecycle-configuration --bucket BUCKET --lifecycle-configuration \
     '{"Rules":[{"ID":"expire-31d","Status":"Enabled","Filter":{"Prefix":"u/"},"Expiration":{"Days":31}}]}'
   ```
   Add `"AbortIncompleteMultipartUpload":{"DaysAfterInitiation":2}` with a `v/` prefix rule for abandoned recordings, and use a longer expiry for `v/` than `VIDEO_RETENTION_DAYS`.
2. **Expire endpoint (authoritative, removes DB rows)**: `POST /v1/internal/expire` with `Authorization: Bearer $CRON_SECRET`. Idempotent and safe if runs overlap (select batch, delete objects, delete rows by id; no locks), processes batches of 500 for up to ~25 s and returns `{expired, purged_pending, purged_sessions, purged_users, expired_videos, aborted_uploads, more}`; call again while `more` is true. Run it hourly or daily:
   - **EventBridge Scheduler**: create a schedule (`rate(1 hour)`) with a universal target of type API destination (HTTP POST to `https://YOUR_HOST/v1/internal/expire`, header `Authorization: Bearer <secret>` stored in the connection).
   - **Any cron**: `0 * * * * curl -fsS -X POST -H "Authorization: Bearer $CRON_SECRET" https://YOUR_HOST/v1/internal/expire`
   - **GitHub Actions**: a workflow with `on: schedule: [{cron: "17 * * * *"}]` running the same `curl` with `${{ secrets.CRON_SECRET }}`.

Videos: the same job deletes expired videos and aborts uploads still pending after 24 hours (objects, multipart upload, comments, reactions and views), under the maintenance RLS bypass.

### Inactive users

Accounts that show no activity for `INACTIVE_USER_DAYS` (default 90; `0` disables) are deleted by the same job. `users.last_seen_at` is set on register and every successful login, and refreshed (at most once an hour, together with the session/token `last_used_at` bookkeeping) whenever a session or API token authenticates, so anyone who still uploads or lists screenshots is never purged. For each user not seen since the cutoff the job (batches of 100 users, within the same time budget) deletes all their screenshot and video objects from the store first, then their screenshot and video rows, sessions, API tokens, login attempts and finally the user. If the store fails, nothing is deleted for that batch and the next run retries (the endpoint returns 502). `purged_users` in the response counts deleted accounts; the email can be registered again afterwards.

Expired links return `410 GONE` immediately, independent of the job. Objects are deleted before their rows; if the store fails, rows are kept and the next run retries (the endpoint returns 502).

S3 bucket CORS is not required (uploads come from a native client, playback uses media elements and transcripts are served same-origin). Keep the bucket private.

## API summary

See the contract in the app repo. Errors are `{"error":{"code","message"}}`. Auth is `Authorization: Bearer <sgs_... session | sgp_... API token>`.

### Email codes (Lettermint)

Registration emails a 6-digit confirmation code. Codes are single use, expire after `AUTH_CODE_TTL_MINUTES`, are stored only as a salted hash, allow 5 guesses each, and are limited to one email per 30 s and 5 per hour per account and purpose. Endpoints that take an email address answer 202 whether or not the account exists; the mail is sent from a background task so timing does not leak either.

| Endpoint | Auth | Body | Result |
|---|---|---|---|
| `POST /v1/auth/verify-email/send` | session | | 202 (200 if already confirmed) |
| `POST /v1/auth/verify-email/confirm` | session | `{code}` | `{email_verified:true}` |
| `POST /v1/auth/password/forgot` | none | `{email}` | 202 |
| `POST /v1/auth/password/reset` | none | `{email, code, new_password}` | 204; revokes all sessions and confirms the email |
| `POST /v1/auth/otp/request` | none | `{email}` | 202 |
| `POST /v1/auth/otp/verify` | none | `{email, code, device_name?}` | same as login; confirms the email |

Failures use `INVALID_CODE` (401); `EMAIL_UNAVAILABLE` (503) means no Lettermint token is configured; `EMAIL_NOT_VERIFIED` (403) is returned for uploads when `REQUIRE_EMAIL_VERIFICATION=true`. Deploy secrets: `LETTERMINT_API_TOKEN`, `MAIL_FROM` (GitHub secrets), `LETTERMINT_ROUTE`, `REQUIRE_EMAIL_VERIFICATION` (GitHub variables); all optional.
