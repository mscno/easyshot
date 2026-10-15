# Shotglass server

Stateless Rust (axum) backend for Shotglass: accounts, presigned screenshot uploads to S3-compatible storage, short share links (`/s/{slug}[.ext]` -> 302 to a short-lived presigned GET), 30-day expiry, and automatic removal of accounts inactive for 90 days. Runs as a container or on AWS Lambda (same Router). Billing is not implemented; `users.plan` exists for later.

Screenshot bytes never pass through the server: the client PUTs directly to the presigned URL, then calls `/complete`.

## Local setup

```sh
cd server
docker compose up -d postgres minio minio-init     # Postgres :5432, MinIO :9000 (console :9001), bucket `shotglass`
cp .env.example .env && set -a && source .env && set +a   # (bash/zsh; or export the vars yourself)
cargo run                                          # migrations run at startup
curl localhost:8080/healthz?db=1
```

Whole stack in containers: `docker compose --profile app up --build`.

No Docker for the database? Use a local libSQL file instead: `DATABASE_URL=file:shotglass.db cargo run` (MinIO or any S3 is still needed for uploads).

Tests: the same integration suite runs against local libSQL (a temp-file database per test, always) and against Postgres when `DATABASE_URL` is a `postgres://` URL (one throwaway schema per test; skipped otherwise):

```sh
cargo test                                         # libSQL only
docker run -d --name pg -e POSTGRES_PASSWORD=pw -e POSTGRES_DB=sg -p 55432:5432 postgres:16
DATABASE_URL=postgres://postgres:pw@localhost:55432/sg cargo test   # both backends
cargo clippy --all-targets -- -D warnings
```

## Database backends

Selected at runtime by the `DATABASE_URL` scheme; the HTTP API is identical.

| URL | Backend |
|---|---|
| `postgres://...`, `postgresql://...` | Postgres via sqlx (pooled, lazy, `DB_MAX_CONNECTIONS`) |
| `libsql://<db>-<org>.turso.io`, `https://...`, `http://...` | Turso / sqld over HTTP; set `DATABASE_AUTH_TOKEN` |
| `file:path.db`, `file::memory:` | local libSQL/SQLite file (dev, tests) |

All SQL lives in `src/repo.rs`, written once in a portable dialect with `?1, ?2` placeholders (rewritten to `$1, $2` for Postgres) on top of `src/db.rs`. Conventions: ids are UUID strings made by the app, timestamps are unix epoch milliseconds set by the app, token hashes are lowercase sha256 hex, booleans are 0/1, there are no foreign keys or cascades (the app deletes child rows). One migration set (`migrations/`, embedded) runs on both dialects via a tiny runner that tracks applied files in `_migrations`; it runs at startup when `RUN_MIGRATIONS=true` (all DDL is `IF NOT EXISTS`). Unique violations map to a single error in both backends (`409 EMAIL_TAKEN` on duplicate email). The libSQL handle and its single connection are created on first use and reused for the life of the process, so startup does no I/O besides migrations.

### Turso setup

```sh
turso db create shotglass                      # pick a region near the Fly region
turso db show shotglass --url                  # libsql://shotglass-<org>.turso.io
turso db tokens create shotglass               # -> DATABASE_AUTH_TOKEN
```

Set `DATABASE_URL=libsql://shotglass-<org>.turso.io` and `DATABASE_AUTH_TOKEN=...` (e.g. `fly secrets set`). Migrations run on first start. Each request costs a few HTTP round-trips to Turso (auth is one joined query), so keep the app and the database in the same region.

### Fly.io notes

The machine can scale to zero: startup only parses config and runs migrations (two cheap queries when up to date). Create the bucket with `fly storage create` (Tigris); it sets `BUCKET_NAME`, `AWS_REGION=auto`, `AWS_ENDPOINT_URL_S3`, `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`, which the server uses as-is (`S3_BUCKET` falls back to `BUCKET_NAME`, `S3_REGION` to `AWS_REGION`, and the SDK reads `AWS_ENDPOINT_URL_S3`; presigned URLs are virtual-hosted style, region `auto`). Do not set `S3_FORCE_PATH_STYLE`. Set `PUBLIC_BASE_URL`, `DATABASE_URL`, `DATABASE_AUTH_TOKEN` and `CRON_SECRET` as secrets/env, and trigger `POST /v1/internal/expire` from an external scheduler (GitHub Actions cron, etc.), since a scaled-to-zero machine cannot run its own timer. The Docker image is non-root and listens on `0.0.0.0:8080`.

## Environment variables

| Var | Default | Notes |
|---|---|---|
| `DATABASE_URL` | required | `postgres://`, `libsql://`, `https://`, `http://` or `file:` (see Database backends) |
| `DATABASE_AUTH_TOKEN` | unset | Turso auth token (remote libsql) |
| `S3_BUCKET` | required | falls back to `BUCKET_NAME` |
| `BIND_ADDR` | `0.0.0.0:8080` | ignored on Lambda |
| `PUBLIC_BASE_URL` | `http://localhost:8080` | used for `share_url` |
| `S3_REGION` | `us-east-1` | falls back to `AWS_REGION` |
| `S3_ENDPOINT` | unset | custom endpoint (MinIO, R2); otherwise the SDK honors `AWS_ENDPOINT_URL_S3` |
| `S3_FORCE_PATH_STYLE` | `false` | `true` for MinIO |
| AWS creds | | standard aws-config chain (env, profile, IAM role) |
| `CRON_SECRET` | unset | enables `POST /v1/internal/expire`; 404 when unset |
| `RETENTION_DAYS` | `30` | |
| `INACTIVE_USER_DAYS` | `90` | purge users not seen for this long; `0` disables |
| `MAX_UPLOAD_BYTES` | `26214400` | |
| `ALLOW_SIGNUPS` | `true` | |
| `RUN_MIGRATIONS` | `true` | |
| `DB_MAX_CONNECTIONS` | `5` | Postgres only: pool is lazy, 5s acquire timeout |
| `LETTERMINT_API_TOKEN` | unset | Lettermint project token (`lm_...`). Enables email; when unset the code endpoints answer 503 |
| `MAIL_FROM` | unset | `Name <sender@verified-domain>`; required with the token |
| `LETTERMINT_ROUTE` | `transactional` | Lettermint route |
| `LETTERMINT_API_URL` | `https://api.lettermint.co/v1` | override for testing |
| `REQUIRE_EMAIL_VERIFICATION` | `true` when the token is set, else `false` | creating uploads needs a confirmed email |
| `AUTH_CODE_TTL_MINUTES` | `10` | lifetime of emailed codes |
| `RUST_LOG` | `info` | JSON logs |

## Deploy to AWS Lambda (cargo-lambda)

```sh
cargo install cargo-lambda
cargo lambda build --release --features lambda --arm64
cargo lambda deploy shotglass-server --enable-function-url   # or put behind API Gateway HTTP API
```

Set the env vars above on the function (use `RUN_MIGRATIONS=true` for the first deploy, or run migrations from a separate job and set it to `false`). Grant the execution role `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject` on `arn:aws:s3:::BUCKET/*` and `s3:ListBucket` on the bucket (HEAD of a missing key returns 404 rather than 403 only with ListBucket). Presigned URLs are signed with the role's credentials, so they expire with the role session; the 1h `image_url` is fine with the normal Lambda credential lifetime. If you use an API Gateway stage path, set `AWS_LAMBDA_HTTP_IGNORE_STAGE_IN_PATH=true`. Use a Postgres reachable from Lambda (RDS Proxy / Neon / Supabase pooler; keep `DB_MAX_CONNECTIONS` small) or Turso. Argon2id uses ~19 MiB per hash, so give the function at least 512 MB.

## Container

```sh
docker build -t shotglass-server .
docker run --env-file .env -p 8080:8080 shotglass-server
```

## Expiry

Screenshots expire `RETENTION_DAYS` after creation. Two layers:

1. **S3 lifecycle rule (backstop)**: expire all objects at 31 days.
   ```sh
   aws s3api put-bucket-lifecycle-configuration --bucket BUCKET --lifecycle-configuration \
     '{"Rules":[{"ID":"expire-31d","Status":"Enabled","Filter":{"Prefix":"u/"},"Expiration":{"Days":31}}]}'
   ```
   (Also aborts nothing else; add `AbortIncompleteMultipartUpload` if you wish.)
2. **Expire endpoint (authoritative, removes DB rows)**: `POST /v1/internal/expire` with `Authorization: Bearer $CRON_SECRET`. Idempotent and safe if runs overlap (select batch, delete objects, delete rows by id; no locks), processes batches of 500 for up to ~25 s and returns `{expired, purged_pending, purged_sessions, purged_users, more}`; call again while `more` is true. Run it hourly or daily:
   - **EventBridge Scheduler**: create a schedule (`rate(1 hour)`) with a universal target of type API destination (HTTP POST to `https://YOUR_HOST/v1/internal/expire`, header `Authorization: Bearer <secret>` stored in the connection).
   - **Any cron**: `0 * * * * curl -fsS -X POST -H "Authorization: Bearer $CRON_SECRET" https://YOUR_HOST/v1/internal/expire`
   - **GitHub Actions**: a workflow with `on: schedule: [{cron: "17 * * * *"}]` running the same `curl` with `${{ secrets.CRON_SECRET }}`.

### Inactive users

Accounts that show no activity for `INACTIVE_USER_DAYS` (default 90; `0` disables) are deleted by the same job. `users.last_seen_at` is set on register and every successful login, and refreshed (at most once an hour, together with the session/token `last_used_at` bookkeeping) whenever a session or API token authenticates, so anyone who still uploads or lists screenshots is never purged. For each user not seen since the cutoff the job (batches of 100 users, within the same time budget) deletes all their screenshot objects from the store first, then their screenshot rows, sessions, API tokens, login attempts and finally the user. If the store fails, nothing is deleted for that batch and the next run retries (the endpoint returns 502). `purged_users` in the response counts deleted accounts; the email can be registered again afterwards.

Expired links return `410 GONE` immediately, independent of the job. Objects are deleted before their rows; if the store fails, rows are kept and the next run retries (the endpoint returns 502).

S3 bucket CORS is not required (uploads come from a native client, not a browser). Keep the bucket private.

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
