# Responses and streams in Topcoat

Easyshot uses Topcoat 0.10's built-in Datastar integration (`topcoat::datastar`, feature `datastar`) and its SSE types (`topcoat::router::content::sse::{Sse, Event, KeepAlive}`). There is no separate Datastar Rust SDK in `Cargo.toml`; do not add one. The upstream [datastar-rust](https://github.com/starfederation/datastar-rust) explains the protocol, but its builder and adapter names are not the APIs used here. Read `~/.cargo/registry/src/*/topcoat-datastar-0.10.0/src` for exact signatures.

| Need | Topcoat API |
| --- | --- |
| Is this a Datastar request? | `datastar_request(cx)` |
| Patch rendered HTML | `PatchElements::new(html)`, `.selector`, `.mode(ElementPatchMode::…)`, `.use_view_transition` |
| Remove | `PatchElements::remove(selector)` |
| Patch signals | `PatchSignals::json(&dto)?`, `.only_if_missing(true)` |
| Read signals | `topcoat::datastar::Signals<T>` (JSON body, or the `datastar` query param on GET) |
| Finite SSE response | `Sse::new(stream::iter(events)).into_response(cx)` (see `watch::patches`) |
| Long-lived stream | `Sse::new(stream).keep_alive(KeepAlive::new().interval(…))` (see `watch::live`) |

Render fragments with the same `#[component]` functions the full page uses, then turn them into strings for `PatchElements` the way `watch.rs` does. Selectors must be application-controlled; line breaks in selectors panic.

## Read the request before returning a stream

Authenticate, bound and validate input, call the service and render the essential fragments before returning SSE. Once the stream starts, status codes, cookies and redirects can no longer change, so session changes (sign-in, sign-out) are full responses, not SSE.

| Request | Decoding |
| --- | --- |
| Enhanced native form | `Form<Input>` with explicit, bounded fields |
| Signals GET/DELETE | `Signals<T>` from the `datastar` query parameter |
| Signals POST/PUT/PATCH | `Signals<T>` from the JSON body |

Decode into input structs, never Toasty models. Keep secrets out of query strings and logs. Map errors through `AppError`/`WebResult`; never send internal error text to clients.

## Navigation and scripts

A fetch 303 does not navigate the top-level page; plain form posts do. Prefer full-page forms for flows that must navigate (sign-in). `ExecuteScript` emits an inline script element; it is subject to CSP and Easyshot does not allow inline scripts. Do not add `'unsafe-inline'` to make it work; use links, forms or a module in `static/app.js`.

## Long-lived streams

Live streams are read-only and authenticated per connection; writes are separate short requests.

- Never hold a Toasty transaction, pool connection or lock for the life of a browser connection. Each re-render opens its own short transaction through `orm::begin` with the viewer's `Context`.
- Keep one stream per page, not per widget. Drive it from an owned stream state (see `watch::Live`): a bounded queue of patches plus a subscription.
- If a broadcast receiver lags, resnapshot everything for that page instead of guessing what was lost.
- Re-check access on every re-render: a video made private, deleted or with a changed password must patch the viewer out (`Live::gone`).
- Clean up subscriptions on drop. Never hold a `std::sync::Mutex` guard across `.await`.
- Keep-alive is 15 s; verify flushing through compression and proxies (Fly) when you change middleware.
- Reconnects (`retry: 'always'`, bounded `retryMaxCount`) re-render from the DB; there is no event replay. A `since` query parameter lets the server skip work when the page is fresh.
- Background tabs: decide per page whether the stream may close while hidden and resnapshot on return.
