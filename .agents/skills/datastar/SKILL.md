---
name: datastar
description: Build, extend, debug or review Easyshot's Datastar web interactions in the Rust server (server/). Use for Topcoat-rendered pages, native forms enhanced by Datastar, element/signal patches, SSE live streams (/v/{slug}/live and friends), and keeping every open page live.
---

# Datastar in Easyshot

Easyshot's web presence lives in `server/` (crate `easyshot-server`). Topcoat 0.10 serves every request and renders pages; Datastar enhances them in the browser. Follow [AGENTS.md](../../../AGENTS.md), the [server README](../../../server/README.md) and the [topcoat-toasty skill](../topcoat-toasty/SKILL.md) for routing, components and persistence.

## Where things are

| Path | Contents |
| --- | --- |
| `server/src/web/mod.rs` | Router: pages, the mounted axum API (`TowerRoute` at `/v1/{*rest}`, `/s/{slug}`, `/healthz`), security headers and CSP, session helpers (`member`) |
| `server/src/web/watch.rs` | Watch page `/v/{slug}`: regions with stable ids, comment/reaction posts, `live` SSE stream |
| `server/src/web/account.rs` | Landing, library, its item actions and `/library/live` |
| `server/src/web/auth.rs` | Sign-up, verify, password and code sign-in, reset, sign-out (plain forms, 303) |
| `server/src/web/settings.rs` | `/account`: verification, password, devices, API tokens, deletion, `/account/live` |
| `server/src/web/layout.rs` | Page shell; loads the one Datastar bundle and `static/app.js` |
| `server/src/web/assets.rs`, `server/static/` | Assets compiled into the binary; `datastar-rocket-1.0.4.js` (Datastar v1.0.4 + Rocket beta.2, MIT, sha256 in `assets.rs`) |
| `server/src/video/{live,scope,service}.rs` | Change fan-out, access scope, video use cases |

Read the handler, its components and `server/tests/web.rs` before changing an interaction.

## Runtime rules

- One runtime per page: the layout loads `/static/datastar-rocket-1.0.4.js`; application modules import from that exact URL. Never add a CDN copy, a second Datastar or Datastar Pro (not installed; see [datastar-pro](../datastar-pro/SKILL.md)).
- Topcoat's own reactive runtime (`runtime()`, shards, procedures, `$(...)`) is not enabled: Datastar owns all client-side DOM. Do not mix the two on a page.
- CSP: `script-src 'self' 'unsafe-eval'`, styles `'self'`. `'unsafe-eval'` is approved because Datastar compiles `data-*` expressions with `Function`. Never add `'unsafe-inline'`, inline `<script>` patches, or new origins without a reason in `web::csp`.
- Upgrading the bundle: replace the file under a new versioned name, update `DATASTAR`, the sha256 and license notes, re-run the browser checks.

## Interaction model

Server-owned state; HTML describes current state and available actions.

| Need | Approach |
| --- | --- |
| Navigate | Ordinary link, full page |
| Sign in / sign up | Native form, full-page response (303 on success) |
| Create, edit, delete | Native POST form enhanced with `@post(url, {contentType: 'form', retry: 'never', retryMaxCount: 0})`; Datastar gets SSE patches, plain posts get 303 |
| Refresh a region | Render the shared component; patch its stable id |
| Live view of shared data | The page's SSE stream re-renders affected regions from the DB |
| Disclosure | Native `details`; signals only when needed |

Writes set both `retry: 'never'` and `retryMaxCount: 0`: Datastar 1.0.2 retried network errors with `retry: 'never'` alone, and this has not been re-verified on 1.0.4. Read streams use `retry: 'always'` with a bounded `retryMaxCount`.

Patterns, patch modes and signal hygiene: [web patterns](references/web-patterns.md). Responses and streaming in Topcoat: [responses and streams](references/rust-sdk.md). The live-everywhere requirement: [live updates](references/live-updates.md). Upstream links: [sources](references/sources.md).

## Fully live across all screens

A product requirement: any change visible on a page must reach every open page showing it, in other tabs, devices and server instances, without reload. When you add data to a page, add it to that page's live stream too (and a test). Streams carry only ids; handlers re-read and re-render through the viewer's scope, so permission changes apply on the next patch. On reconnect, re-render from the DB; never replay commands.

## Boundaries

- Authenticate and authorize on the server (`member`, `video::scope::Scope`). Never put identity, tokens, permissions or other users' data in signals; an `_`-prefixed signal is merely not sent, not private.
- Escape all user content through Topcoat `view!` interpolation; never splice user text into expression source.
- Correctable form errors re-render the form with safe attempted values and field errors (never refill passwords). Unexpected errors go through `AppError` and are logged once.
- Rate limits and origin checks live in `web/mod.rs` and `video/limit.rs`; keep new mutating endpoints behind them.
- Give every patch target a unique, stable id present in the initial page; repeated items need per-item ids.
- Include a polite status/live region before patching routine messages; preserve focus and drafts across morphs.

## Verify

- `mise run server:test` (HTTP tests in `server/tests/web.rs` check content types, patches, 303 fallbacks, access), `cargo clippy --all-targets -- -D warnings`, `cargo fmt --check`, `topcoat fmt --check`.
- Reactive behavior needs a real browser (Playwright was used): console and CSP errors, request payloads, morph/focus, both the enhanced and the plain-form path, two tabs for live updates, reconnect after a server restart.
- Say which of these you actually ran.
