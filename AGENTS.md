# AGENTS.md

Repository instructions for coding agents. `CLAUDE.md` includes this file.

**Easyshot** (formerly Shotglass): a native, ultra-fast macOS capture app — screenshots, annotation, OCR, recordings, Studio export, an MCP server for AI agents — plus Easyshot Cloud, a Rust web service for instant share links and Loom-style video pages with live comments.

## Layout

| Path | Contents |
| --- | --- |
| `Sources/Easyshot` | The app: AppKit/SwiftUI UI, ScreenCaptureKit capture, recorder, editor, Studio, MCP server (`--mcp`), Cloud client |
| `Sources/EasyshotCore` | Pure, unit-tested logic (geometry, selection, MCP framing, Studio planning, secret scanner, …) |
| `Tests/EasyshotCoreTests`, `Tests/Release` | Swift unit tests; release-script tests |
| `scripts/` | `build-app.sh`, release, notarization, DMG, App Store packaging |
| `integrations/raycast` | Raycast script commands (`easyshot://` URLs) |
| `server/` | `easyshot-server`: Topcoat web + mounted axum JSON API, Toasty on PostgreSQL with row-level security, migrations, tests |
| `docs/` | MCP, performance, releasing, App Store |
| `.agents/skills` | `datastar`, `datastar-pro`, `datastar-rocket`, `topcoat-toasty` (linked from `.claude/skills`) |

## Commands

Mac app:

| Command | Purpose |
| --- | --- |
| `swift build -c release --arch arm64` | Build |
| `swift test` | Unit tests |
| `bash scripts/build-app.sh [debug]` | Package `dist/Easyshot.app`. Without `SIGNING_IDENTITY` this is the dev bundle `no.paraply.easyshot.dev` ("Easyshot Dev", `easyshot-dev://`), signed with a stable keychain identity so privacy permissions persist across rebuilds |
| `open -W --stdout F --stderr F dist/Easyshot.app --args --self-test` | Offline diagnostics; also `--capture-test` (needs Screen Recording), `--studio-test`, `--editor-test`. Running through LaunchServices keeps the app's own permissions |
| `dist/Easyshot.app/Contents/MacOS/Easyshot --mcp` | Stdio MCP server (see `docs/MCP.md`) |

Server (tasks in `mise.toml`; local Postgres `postgres:postgres@localhost:5432`):

| Command | Purpose |
| --- | --- |
| `mise run db:create` / `db:migrate` / `db:status` / `db:seed` | Dev database `easyshot_dev` (migrations as the owner) |
| `mise run db:reset` | Rebuild the dev schema (dev/test databases only) |
| `mise run db:new -- name` | New migration file |
| `mise run db:test` / `db:test:reset` | Test database `easyshot_test` |
| `mise run server:dev` | Run against the dev DB and local MinIO (`docker compose -f server/docker-compose.yml up -d minio minio-init`) |
| `mise run server:test` | Server suite (one throwaway schema per test, as the app role) |
| `cd server && cargo clippy --all-targets -- -D warnings && cargo fmt --check && topcoat fmt --check` | Lint and format |

Create databases only through these tasks.

## Workflow

- `easyshot` is the integration branch; `master` holds the last release.
- Concurrent agents work in their own worktree and branch, commit only the files they were assigned, and hand commits to the integrator, who merges into `easyshot`. Never share an index or edit the same files concurrently.
- Commit in logical steps with clear messages. Do not push, tag or release unless asked.
- Run the smallest useful checks while iterating; run the full suites for the area you touched before handing off. Report exactly what ran, what passed and what was not verified (live capture, UI interaction and browser behavior often need a person or a real browser).

## Conventions

Swift:
- Match the dense style of the surrounding files (compact expressions, few comments, explaining *why*).
- Pure logic goes in `EasyshotCore` with unit tests; app code stays thin.
- Preferences: one `Preferences` type plus feature extensions (`Preferences+Capture.swift`, `+Editor`, …) backed by `UserDefaults`.
- Respect the lifecycle: no daemon, login item or global hotkey registration; the app quits when idle. Hotkeys come from App Intents, Raycast or `easyshot://` URLs.
- Store edition (`APP_STORE` flag) has no Sparkle and stricter sandbox rules; keep both editions building.

Server (details in the skills and `server/README.md`):
- PostgreSQL only; **Toasty is the one database library** (raw `toasty::sql` where the builder is not enough). No sqlx in new code.
- Every unit of work is a Toasty transaction from `orm::begin` with the RLS `Context`. Filter explicitly through `video::scope::Scope`; RLS is the second wall. The share-link path is the single marked bypass.
- `server/migrations/*.sql` owns the schema; new owned tables get FORCEd policies, grants and RLS tests.
- Web: Topcoat SSR + one self-hosted Datastar/Rocket bundle; native forms enhanced by Datastar; every visible change is live on every open page (SSE re-render from the DB, fan-out via Postgres NOTIFY).
- CSP allows `'unsafe-eval'` for Datastar and nothing inline.

Security:
- Never log or put in signals, URLs or MCP output: tokens, passwords, session ids, secrets. Secrets come from env/esec (`.env.*` are encrypted or gitignored).
- Treat client input, signals, persisted browser state and agent arguments as untrusted.
- Uploads run the secret scanner first (UI review; MCP refuses unless `redact`/`allow_secrets`).

## Performance principles

- Nothing runs when Easyshot is idle. Startup to an interactive capture bar is measured (`--startup-benchmark`); do not add work to that path.
- No desktop streaming in the selector; capture only when asked. Keep per-frame recording work on the GPU or passthrough; measure before/after for any change to capture, recording or export paths and report numbers.
- Media bytes never pass through the server (presigned S3). Server pages render in single-digit milliseconds; keep queries bounded and avoid N+1; streams never hold DB connections.
