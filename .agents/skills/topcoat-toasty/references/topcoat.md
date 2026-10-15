# Topcoat patterns (0.10)

Baseline: Topcoat 0.10.0 as pinned in `server/Cargo.lock`, features `router, serve, view, cookie, session, datastar, tower, compression`. The crate's own docs (`docs/*.md` in the unpacked source) are the most precise reference.

## Routing and responses

- Easyshot registers handlers explicitly in `web::router` (`.page(handler)`, `.route(handler)`), not with `module_router!`/`.discover()`. Duplicate method/path registrations are errors to fix, not shadows.
- `#[page("/v/{slug}")]` serves GET; `#[route(POST "/library/{id}/rename")]` declares other methods. Read typed segments with `path_param::<T>(cx)`; query strings with `query_params::<T>(cx)`.
- The JSON API is an axum `Router` mounted with `TowerRoute::any("/v1/{*rest}", api)` and `TowerRoute::new(Method::GET, …)`. Keep API handlers in axum (`src/routes`) so the `lambda` feature can serve them alone.
- After a successful native form post, return `see_other(url)` (303). Datastar requests (`datastar_request(cx)`) get SSE patches instead.
- Map invalid input, missing records and denied access through `WebResult`/`AppError` to the right status; missing and foreign items both look like 404.

## Rendering

- `view!`: literal text in quotes, dynamic values as `(value)` (escaped). Numbers interpolate directly. Never render untrusted data unescaped.
- `#[component] async fn name(arg: T, #[default] opt: U, child: Child<'_>) -> Result<impl View>`; `attributes!`/`class!` for forwarding and conditional classes.
- Views evaluate lazily and concurrently; output order is source order, execution order is not. Perform writes and ordered effects before building the view.
- Boolean attributes: `hidden=(bool)`, `disabled=(bool)`; ARIA values need `"true"`/`"false"` strings.
- Lists of stateful items: stable HTML ids per item so Datastar morphs keep identity.
- The page shell is `layout::shell(meta: Meta, signed_in: bool, …)`; it loads the Datastar bundle and `app.js` once.

## Context, auth and sessions

- `AppState` is app context; borrow it through `web::state(cx)`. Required lookups panic when absent.
- Put request-wide reads and guards in small functions taking `&Cx` (`member`, `scope_of`); call them where data is read or changed. Each endpoint authorizes itself: SSE endpoints and form posts do not inherit page guards.
- Sessions: `.cookies()` then `.sessions(SessionConfig…CookieTokenStore…)`. Topcoat issues tokens; Easyshot stores their hash in the `sessions` table with user, expiry and device, deletes it on sign-out, and rejects expired rows. Set or clear cookies before returning a streaming response.
- Keep signing/encryption keys (`WEB_SECRET`) stable across restarts and instances.

## Runtime boundaries

Topcoat's native runtime (`runtime::script()`, `#[shard]`, `#[procedure]`, `$(...)`) is not enabled in Easyshot; Datastar owns the client. If that ever changes, give the two runtimes disjoint DOM and treat shard/procedure endpoints as independently reachable (authorize inside them).

## Assets and formatting

- Assets are compiled into the binary by `web::assets` and served from `/static/`; app files use a content-hash `?v=` and immutable caching; the vendored Datastar file carries its version in its name. (Topcoat's `asset!`/`AssetBundle` pipeline is not used.)
- Format macro bodies with `topcoat fmt` (`cargo install topcoat-cli`), ordinary Rust with `cargo fmt`; check both in CI.

## Upstream

[docs.rs topcoat 0.10](https://docs.rs/topcoat/0.10.0/topcoat/) — router, view, context, session, cookie, datastar, tower modules. Prefer the pinned version's docs over `main`.
