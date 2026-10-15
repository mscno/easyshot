# Easyshot server

Rust backend and web presence for Easyshot: accounts, presigned screenshot uploads with short share links (`/s/{slug}[.ext]`), Loom-style video sharing (instant links, a watch page with timestamped comments, reactions and transcripts), retention, and automatic removal of accounts inactive for 90 days. PostgreSQL only. Billing is not implemented; `users.plan` exists for later.

Media bytes never pass through the server: clients PUT straight to presigned URLs (screenshots as one object, recordings as S3 multipart parts streamed while recording), and viewers are redirected to short-lived presigned GETs.

## Architecture

- **One binary, one HTTP host.** Topcoat (0.10) serves every request. The JSON API is an axum `Router` (`src/routes`) mounted unchanged through `TowerRoute` at `/v1/{*rest}`, `/s/{slug}` and `/healthz`; web pages are Topcoat handlers in `src/web`. The `lambda` feature still builds the API-only axum router for AWS Lambda; the web pages need the container (Fly) deploy.
- **Data access: one library, one pool.** Toasty 0.11 is the only database library. The video domain (`videos`, `item_comments`, `item_reactions`, `item_views`) uses Toasty models (`src/video/model.rs`); users, sessions, auth codes, API tokens and screenshots use raw SQL through the same Toasty pool (`toasty::sql` behind `db::Db`, `src/repo.rs`), because that layer leans on `ON CONFLICT` upserts, aggregates, `RETURNING` and multi-table purges that read more clearly as SQL. Toasty binds typed parameters, so `Db` inlines `NULL` arguments as literals and Postgres types them from context. The pool connects as the app role and opens four connections at startup, so the first request does not pay for TCP, TLS and authentication. Two single `tokio-postgres` connections (Toasty's own driver dependency, `src/pg.rs`) do what a pool cannot: migrations as the owner (`batch_execute` for multi-statement files) and the live-update `LISTEN` session.
- **Schema ownership.** `migrations/*.sql` owns every table, including those Toasty maps; Toasty never creates or alters schema. Files are embedded at build time (`build.rs`), applied in name order as the owner role inside one transaction each, under an advisory lock, and recorded in `_migrations`. New migrations: `mise run db:new -- name` (next `000N_` number).
- **Team-ready, without teams.** Every video-domain table has a nullable `workspace_id`; conversation tables reference a generic `item_id` and `videos` has a `kind`, so videos can later merge with screenshots into one `items` table with child assets; `visibility` is an application enum (`link`, `password`, `private`) stored without a CHECK constraint so it can gain `workspace`; all access decisions go through one scope helper (`src/video/scope.rs`).
- **Live updates, across instances.** Every page that shows changing data holds one Datastar SSE stream: the watch page (`/v/{slug}/live`), the library (`/library/live`) and the account page (`/account/live`). Triggers (`migrations/0005_live_notify.sql`, `0006_upload_progress_and_live.sql`) on `videos`, `item_comments`, `item_reactions`, `item_views`, `screenshots`, `sessions` (sign-in, rename, removal; not `last_used_at`), `api_tokens` and `users` (email, verification, password) send `NOTIFY easyshot_live` with ids and kinds only (`{t, item, owner, ws, op}`), never content or tokens; conversation rows carry the item's `owner_id` so the owner's library hears about them. Each process holds one `LISTEN` connection, opened when the first page subscribes, and fans notifications out by topic: an item id, `user:{id}` for pages showing one owner's things, and `session:{id}` (the session row id) for every stream opened with that session (`src/video/live.rs`). Streams re-authorize on every render (a revoked session gets a sign-in redirect patch, a lost permission an unavailable or password state), re-read what changed under the viewer's own RLS context and patch it by id; list pages patch only the row that changed, and progress ticks patch only the card's status line so an open "Manage" panel and typing survive. Bursts coalesce into one render. Each session may hold 12 open streams (anonymous viewers 24 per address); more get 429. Every listener (re)connect sends a resync to all open streams, and reconnects back off from 250 ms to 30 s. A write on one machine reaches a viewer on another in about 20 ms locally (`tests/web.rs`, `live_updates_cross_server_instances`). There is no polling; a 15 s SSE keep-alive holds proxies open, and streams close while the tab is hidden.
- **Browser runtime.** One self-hosted bundle, `static/datastar-rocket-1.0.4.js` (Datastar v1.0.4 + Rocket beta.2, MIT, `static/DATASTAR-LICENSE.md`, sha256 `c723fb309157a555609df273e4693dcc4e193e68e6d7477f3285b955288e1e7b`), loaded once by the layout and imported by `static/app.js` from the same URL. Topcoat's own reactive runtime is not enabled. `<easyshot-player>` is a light-DOM Rocket component over a native `<video controls>`, which also works without JavaScript. Forms are native posts that Datastar enhances (form encoding, retries off). Assets are compiled into the binary and cached immutably.

## Database roles and row-level security

Migrations run as the table owner (`MIGRATION_DATABASE_URL`, or `--database-url`). The server connects as `easyshot_app` (`DATABASE_URL`), created by migration `0004_rls_app_role` with `NOSUPERUSER NOBYPASSRLS` and the development password `easyshot_app` when it does not exist yet (local and test databases only). In production `mise run db:bootstrap` creates the role with its own password first, so the migration only grants (see Deploy). A superuser or `BYPASSRLS` connection defeats RLS.

`screenshots`, `videos`, `upload_parts` (owner and maintenance only) and the `item_*` tables have `FORCE`d policies keyed on transaction-local settings, set with `set_config(..., true)` as the first statement of every transaction:

| Setting | Grants |
|---|---|
| `app.user_id` | the owner's rows (and their items' conversation) |
| `app.workspace_id` | reserved: items of that workspace |
| `app.share_slug` | read-only access to the one item with that slug (public share-link path) |
| `app.share_item_id` | with the matching slug: read and insert that item's comments, reactions and views |
| `app.rls_bypass = 'maintenance'` | everything; retention and account purge only (`Context::maintenance`) |

Raw SQL applies a `db::Context` per statement (`Db::scoped` runs each statement in a Toasty transaction whose first statement is the `set_config`); model work runs inside `orm::begin`, which does the same for a multi-statement Toasty transaction. Without a context, owner-scoped tables read as empty. `users`, `sessions`, `auth_codes`, `api_tokens` and `login_attempts` have no policy on purpose: they are read before a principal is known and every query filters by an explicit user id, email or token hash. `tests/rls.rs` runs unfiltered SQL as the app role to show the database itself denies cross-owner, cross-workspace and out-of-share reads and writes, including inside Toasty transactions.

## Local setup

Requires PostgreSQL 18 on `localhost:5432` (user/password `postgres`), [mise](https://mise.jdx.dev) and Docker for MinIO. Tasks live in the repository's `mise.toml`:

```sh
docker compose up -d minio minio-init     # MinIO :9000 (console :9001), bucket `easyshot`
mise run db:create                         # easyshot_dev
mise run db:migrate                        # as the owner; creates easyshot_app
mise run db:seed                           # dev@easyshot.test / teammate@easyshot.test
mise run server:dev                        # http://127.0.0.1:8080, app role, MinIO
```

`db:status`, `db:reset` (dev only: drops and rebuilds `public`), `db:new -- name`, `db:test` and `db:test:reset` work the same way. Override `DEV_DATABASE_URL`, `TEST_DATABASE_URL` or `DEV_APP_DATABASE_URL` in `mise.local.toml`. Without Lettermint, web sign-in codes cannot be mailed; the API (`/v1/auth/login`) still works with the seeded password `easyshot-dev-password`.

Tests run against `TEST_DATABASE_URL` (default `easyshot_test` on :5432), one throwaway schema per test, migrated as the owner, with the code under test connected as `easyshot_app`:

```sh
mise run server:test                       # or: cd server && cargo test
cargo clippy --all-targets -- -D warnings
cargo fmt --check && topcoat fmt --check src tests   # cargo install topcoat-cli --version 0.10.0
```

CI (`.github/workflows/server-ci.yml`) runs the same checks against a `postgres:18` service container on every server change, plus `cargo-audit` 0.22.2, and the deploy workflow runs it before deploying. The S3 SDK selects its current HTTPS client explicitly; the deprecated Hyper 0.14 / rustls 0.21 connector is disabled. The audit has no vulnerability findings; Toasty 0.11 still brings an upstream maintenance warning for `rustls-pemfile` 2.2.0 (not suppressed).

Whole stack in containers: `docker compose --profile postgres --profile app up --build`.

The binary's own commands: `easyshot-server [serve]`, `migrate up|status|reset --yes`, `seed`, `db bootstrap|verify` (owner URL via `--database-url` or `MIGRATION_DATABASE_URL`).

## Web pages

| Path | Page |
|---|---|
| `/` | Landing page; download link from `DOWNLOAD_URL` |
| `/v/{slug}` | Watch page: player, transcript (from the WebVTT track; click a line to seek), timestamped comments (guests name themselves and are labelled guests; members come from the session), emoji reactions, view count, copy link, download. While the app records it shows "Recording live… N MB uploaded", then "Finishing…", then swaps in the player live. Password videos show a gate; private and expired ones are 404. Open viewers follow changes: a switch to password shows the gate, deletion or "only me" shows "Recording unavailable". Open Graph, Twitter player and oEmbed discovery tags for link-visible videos. |
| `/v/{slug}/embed` | Player only, frameable (oEmbed `html`) |
| `/v/{slug}/media`, `/download`, `/thumbnail.jpg` | 302 to presigned GETs (5 min, 10 min, 10 min) after the access check |
| `/v/{slug}/transcript.vtt` | The transcript, same origin so `<track>` needs no bucket CORS |
| `/v/{slug}/live` | Datastar SSE stream |
| `POST /v/{slug}/comments`, `/reactions`, `/unlock` | Native forms; Datastar gets SSE patches, plain posts a 303 |
| `/oembed?url=` | oEmbed JSON for link-visible, ready videos |
| `/signup`, `POST /signup` | Email + password (10–256 characters, argon2id, like the API); honours `ALLOW_SIGNUPS`. With mail configured it emails a verification code and shows `/verify`; an email that already has an account gets the same page and a sign-in code instead (no account enumeration). Without mail (local dev) it signs straight in. 5 per hour per address. |
| `/verify`, `POST /verify`, `POST /verify/resend` | Enter an emailed code; password-carrying codes also require the hidden signup-attempt nonce. The first mailbox proof installs that attempt’s password and revokes earlier sessions, API tokens and codes |
| `/login`, `POST /login` | Password sign-in; same `login_attempts` lockout as the API (10 failures per email per 15 min) plus 20 posts per 10 min per address |
| `/login/code`, `POST /login/code` | "Email me a sign-in code" (`login_otp`) |
| `/forgot`, `POST /forgot`, `POST /reset` | Password reset with an emailed code; ends every session, revokes every API token and outstanding code, and signs this browser in |
| `POST /logout` | Ends this browser's session |
| `/account` | Email and verification, change password (ends every other session), signed-in devices (Mac app and browsers; sign out one or all others), API tokens (shown once on creation, revocable), delete account (type the email to confirm; purges recordings, screenshots, sessions and tokens) |
| `/account/live`, `/library/live` | Datastar SSE streams for those pages |
| `/library` | The owner's videos and screenshot links: rename, visibility (link / password / only me), send to an email address (Lettermint, 20 per hour), delete. Recordings appear when the app creates them and show upload progress, comment and view counts live. |

Sessions: every sign-in replaces the browser's `__Host-sg_session` cookie with a new token (any earlier one is deleted) and stores only its hash in `sessions`, with a device label such as "Safari on macOS". `last_used_at` is refreshed at most every five minutes.

Security: Topcoat's origin policy rejects cross-site state-changing browser requests; the CSP allows scripts and styles only from `'self'`, plus `'unsafe-eval'` (accepted deliberately: Datastar compiles each `data-*` expression with `Function`, and has no build-time compilation mode; every expression is server-authored, user data only ever appears as escaped text or attribute values, and inline `<script>` stays blocked), media and images from `https:` (and a plain-HTTP dev store); comment, reaction, unlock and sign-in posts are rate limited per client address or user; password unlocks are an HMAC cookie bound to the current password hash; views are counted once per viewer per UTC day using a keyed hash of day, address and user agent.

## Authentication API

With mail configured, `POST /v1/auth/register {email, password, device_name?}` returns `202 {verification_required: true, attempt}` for every valid address (new, unverified, verified or disabled), without a session. The random attempt is 43 URL-safe characters; only its hash is stored, alongside the signup password hash on the mailed code. `POST /v1/auth/login` returns that same shape for a correct password on an unverified account; a verified account gets `200 {token, expires_at, user}`. Wrong credentials remain 401. Without mail, development registration returns 201 with a session and duplicate addresses return 409.

`POST /v1/auth/otp/verify {email, code, attempt?, device_name?}` completes signup or sign-in. A password-carrying verification code requires its matching attempt; independent signup attempts cannot redeem or cancel each other's codes. The first proof of an unverified mailbox atomically installs that attempt's password, verifies the account and revokes all earlier sessions, API tokens and outstanding codes. A passwordless sign-in code claims without retaining a preregistered password; the owner can set one through password recovery. Authenticated email confirmation preserves that session's credentials. Unverified accounts cannot create API tokens while mail is configured.

`POST /v1/auth/otp/request {email, attempt?}` resends a signup code with the same attempt and password, or requests a passwordless sign-in code without an attempt. Resending never moves a code to another attempt. Code issuance is serialized per account/purpose: 30 seconds between sends, at most five per hour, five guesses per code, single use. Password reset revokes sessions, API tokens and outstanding codes in one transaction.

Web and API requests share per-address budgets before password hashing: login 20/10 min, signup 5/hour, code requests 10/10 min and verification/reset 20/10 min. Addresses follow `TRUSTED_PROXY_HOPS`; client-supplied leftmost forwarding entries are ignored. Concurrent Argon2 work is bounded and per-email failures are recorded before checking passwords (10 failures/15 min).

Media signatures are bearer capabilities: a URL already issued remains usable until expiry, even after a privacy or password change. Media GET signatures last five minutes, and their redirect responses are not cached. The player re-enters the authorized media route after an expiry error and preserves playback position. Live pages remove inaccessible players immediately; bytes already downloaded cannot be recalled. Downloads and thumbnails retain their ten-minute signatures.

## Video upload API

Auth as for screenshots (`Authorization: Bearer ...`; uploads need a confirmed email when `REQUIRE_EMAIL_VERIFICATION=true`). The share link exists before any bytes are uploaded.

| Endpoint | Body | Result |
|---|---|---|
| `POST /v1/videos` | `{title?, content_type?}` (`video/mp4` default, `video/quicktime`, `video/webm`) | 201 video JSON with `share_url` and `upload: {min_part_bytes, max_bytes, max_parts, max_part_batch, part_url_ttl_seconds}`. 429 `TOO_MANY_PENDING_UPLOADS` when the account already has `MAX_PENDING_UPLOADS` unfinished uploads |
| `POST /v1/videos/{id}/parts` | `{parts: [{part_number, size}, ...]}` (≤ 100 per call, part numbers 1..=10000, sizes 1..=5 GiB) | `{parts: [{part_number, method: "PUT", url, headers: {"content-length"}}], expires_in}`; PUT exactly `size` bytes (the length is signed into the URL) and keep each `ETag`. Sizes are reserved before signing and fixed per part (asking again with the same size is fine, another size is 400). 413 `TOO_LARGE` when the video's parts would exceed `MAX_VIDEO_BYTES` or the account's unfinished uploads `MAX_PENDING_UPLOAD_BYTES`; a refused batch reserves nothing |
| `POST /v1/videos/{id}/progress` | `{uploaded_bytes, recording}` | 204. About once per second while recording; at most 4 per second per video (429 beyond). Counts must not decrease (400); `recording: false` records when recording stopped; ignored once the video is ready. Drives "Recording live… N MB uploaded" / "Finishing…" on every open page. |
| `POST /v1/videos/{id}/complete` | `{parts: [{part_number, etag}], duration_ms?, width?, height?}` (up to 10,000 parts; ETags optionally quoted, ≤ 64 of `[A-Za-z0-9_-]`) | video JSON (`status: ready`). Every part must have been requested (400 otherwise); the object must measure the reserved sizes of the listed parts. Idempotent: a retry after storage already assembled the object finishes the transition (200); an aborted or mismatching upload is 409 `NOT_UPLOADED` |
| `POST /v1/videos/{id}/thumbnail` | `{byte_size}` (JPEG, ≤ 2 MiB) | `{upload: {method, url, headers}}`; presign only |
| `POST /v1/videos/{id}/thumbnail/complete` | | after the PUT: checks the object (exists, ≤ 2 MiB, `image/jpeg`) and publishes it; video JSON, or 409 `NOT_UPLOADED` (a mismatching object is deleted) |
| `POST /v1/videos/{id}/transcript` | `{byte_size}` (WebVTT, ≤ 1 MiB) | `{upload: {method, url, headers}}`; presign only |
| `POST /v1/videos/{id}/transcript/complete` | | as for the thumbnail (≤ 1 MiB, `text/vtt`); open watch pages show the transcript and captions live |
| `GET /v1/videos`, `GET /v1/videos/{id}` | | the caller's videos |
| `PATCH /v1/videos/{id}` | `{title?, visibility?, password?}` | video JSON |
| `DELETE /v1/videos/{id}` | | 204; aborts the upload, deletes objects and conversation |

Every part except the last must be at least 5 MiB (S3 rule). Upload parts while recording and complete on stop; the watch page flips to the player within a moment. Reservations live in `upload_parts` (migration `0009`, owner-only RLS); creating uploads, reserving parts and completing serialize per account with a transaction-scoped advisory lock, so the caps hold under concurrent requests. Stale uploads continue counting until actually purged; their parts cannot be presigned after 24 h. Completion and deletion release the reservation. The completion route accepts bodies up to about 1.6 MB (a 10,000-part manifest); the rest of `/v1` keeps the 64 KiB limit.

## Deploy (Fly.io + PostgreSQL)

Production is PostgreSQL, e.g. Fly Managed Postgres or Neon, with two connection strings: the owner (`MIGRATION_DATABASE_URL`) and `easyshot_app` (`DATABASE_URL`). TLS follows `sslmode` (`require` verifies the server certificate against the platform roots; use `disable` only on a private network).

Once per database, and again to rotate the password:

```sh
MIGRATION_DATABASE_URL=postgres://owner:...@host/db?sslmode=require \
APP_DATABASE_PASSWORD="$(openssl rand -base64 32)" mise run db:bootstrap
# creates or rotates easyshot_app (LOGIN NOSUPERUSER NOBYPASSRLS), grants CONNECT, migrates
MIGRATION_DATABASE_URL=... DATABASE_URL=postgres://easyshot_app:...@host/db?sslmode=require mise run db:verify
# ok/FAIL per check: app role is not a superuser, cannot bypass RLS, owns no tables, does not
# use the development password; recursive inherited/SET ROLE privileges and object ownership
# are checked, schema SECURITY DEFINER functions and the role-grant helper cannot be called;
# all migrations applied; every owner-scoped table FORCEs RLS
```

Without the variables, both tasks load the encrypted `.env.production` at the repository root with `esec` (`server/scripts/run-production-db.sh`). Neon: the `*_owner` role can create the app role; Fly MPG: the provided owner user. Set `DATABASE_URL` to the app role with the new password. `fly.toml` runs `easyshot-server migrate up` as the release command, so migrations apply as the owner before new machines start; the app itself never needs the owner URL. Use the pooled endpoint for `DATABASE_URL` only if it is a session pooler: transaction-mode pooling breaks prepared statements and transaction-local settings stay safe only within a transaction.

The machine can scale to zero: startup parses config and opens the warm pool (four connections, a few milliseconds). Create the bucket with `fly storage create` (Tigris); it sets `BUCKET_NAME`, `AWS_REGION=auto`, `AWS_ENDPOINT_URL_S3`, `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`, which the server uses as-is (presigned URLs are virtual-hosted style, region `auto`). Do not set `S3_FORCE_PATH_STYLE`. Secrets: `DATABASE_URL`, `MIGRATION_DATABASE_URL`, `CRON_SECRET`, `PUBLIC_BASE_URL`, `WEB_SECRET` (synced from GitHub secrets by `.github/workflows/deploy-server.yml`). `TRUSTED_PROXY_HOPS=1` makes client addresses come from Fly's proxy. Trigger `POST /v1/internal/expire` from an external scheduler, since a scaled-to-zero machine cannot run its own timer. Live updates travel through Postgres `LISTEN/NOTIFY`, so any number of machines stay in step without extra infrastructure; `DATABASE_URL` must reach Postgres directly or through a session-mode pooler, since `LISTEN` does not survive transaction pooling.

There is no migration from the earlier Turso/libSQL backend: production starts fresh on PostgreSQL. Shotglass Cloud links expired after 30 days anyway; existing users sign up again.

## Environment variables

| Var | Default | Notes |
|---|---|---|
| `DATABASE_URL` | required | app role (`easyshot_app`), `postgres://` |
| `MIGRATION_DATABASE_URL` | unset | owner role; used by `migrate`, and at startup when `RUN_MIGRATIONS=true` |
| `RUN_MIGRATIONS` | `false` | apply migrations at startup (needs `MIGRATION_DATABASE_URL`) |
| `DB_MAX_CONNECTIONS` | `5` | the one Toasty pool; up to four open at startup, 5 s acquire timeout. Plus one `LISTEN` connection per machine once a live page is open |
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
| `MAX_PENDING_UPLOADS` | `3` | unfinished recording uploads per account |
| `MAX_PENDING_UPLOAD_BYTES` | `MAX_VIDEO_BYTES` | bytes one account may reserve across its unfinished uploads |
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
cargo lambda deploy easyshot-server --enable-function-url   # or put behind API Gateway HTTP API
```

Set the env vars above on the function and run migrations separately (`easyshot-server migrate up` with the owner URL). Grant the execution role `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject`, `s3:AbortMultipartUpload` on `arn:aws:s3:::BUCKET/*` and `s3:ListBucket` on the bucket (HEAD of a missing key returns 404 rather than 403 only with ListBucket). Presigned URLs are signed with the role's credentials, so they expire with the role session. If you use an API Gateway stage path, set `AWS_LAMBDA_HTTP_IGNORE_STAGE_IN_PATH=true`. Use a Postgres reachable from Lambda (RDS Proxy in session mode / Neon; keep `DB_MAX_CONNECTIONS` small). Argon2id uses ~19 MiB per hash, so give the function at least 512 MB.

## Container

```sh
docker build -t easyshot-server .
docker run --env-file .env -p 8080:8080 easyshot-server
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
