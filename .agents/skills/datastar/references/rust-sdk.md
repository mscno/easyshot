# Rust SDK and streaming

Start with [Topcoat Datastar](https://docs.rs/topcoat/latest/topcoat/datastar/index.html), selected by Billit's architecture. There is no installed Rust workspace yet. Inspect the eventual lockfile and Topcoat adapter before adding another SDK. The [official Rust SDK](https://github.com/starfederation/datastar-rust) and its [examples](https://github.com/starfederation/datastar-rust/tree/main/examples) explain protocol builders, but are not automatically the APIs exposed by Topcoat. Datastar Rocket browser widgets and the Rust Rocket web framework are separate technologies.

The SDK's [module definitions](https://github.com/starfederation/datastar-rust/blob/main/src/lib.rs) expose event builders; the HTTP framework owns response streaming. Do not translate Go's `NewSSE`, `ResponseWriter`, or goroutine lifecycle literally.

## Read the request before returning a stream

Authenticate, bound input sizes, parse/validate, call the service, and render essential fragments before returning a finite SSE response. Once headers/body are sent, status codes, cookies, and normal redirects cannot be changed. Keep fallible setup outside lazy stream generation where possible.

| Request contract | Rust decoding approach |
| --- | --- |
| Enhanced native form | Framework URL-encoded form extractor with a feature-appropriate body limit |
| Multipart form | Size-limited multipart extractor/streaming parser; release temporary resources |
| Default signal GET or DELETE | URL-decode the `datastar` query parameter, then deserialize its JSON |
| Default signal POST/PUT/PATCH | Deserialize the JSON request body |

Verify transport behavior against both selected versions. Use the SDK's framework signal extractor when available; it does not replace size limits or domain validation. A form payload is not signal JSON. Decode into explicit `serde::Deserialize` input DTOs, never domain entities. Decide intentionally whether unknown fields are ignored or rejected; a page may send signals unrelated to this endpoint. Keep secrets out of query strings and payload logs. See [backend requests](https://data-star.dev/guide/backend_requests).

## Select event builders

The following are upstream Rust SDK API shapes inherited from the source skill, not qualified Topcoat APIs. Prefer Topcoat's selected integration; inspect its implementation before adapting these examples.

| Need | Builder |
| --- | --- |
| Patch rendered HTML | `PatchElements::new(html).selector("#target")` |
| Change patch mode | `.mode(ElementPatchMode::Inner)` or the chosen supported mode |
| Remove a target | `PatchElements::new_remove("#target")` |
| Patch signals | `PatchSignals::new(serialized_json)` |
| Initialize missing signals | `.only_if_missing(true)` |

See [element builders](https://github.com/starfederation/datastar-rust/blob/main/src/patch_elements.rs) and [signal builders](https://github.com/starfederation/datastar-rust/blob/main/src/patch_signals.rs). Serialize signal DTOs with `serde_json::to_string` and handle the `Result` before returning SSE. Do not use `unwrap()` on request-dependent rendering or serialization. Render HTML through the chosen escaping template engine; IDs/selectors must be controlled by the application.

Convert builders to the selected framework's SSE events using that SDK integration. Return a response stream that owns its data/state for the required lifetime. With Axum, inspect the installed SDK adapter and Axum `Sse` APIs; returning event text as ordinary `Html` is not streaming. Set `text/event-stream` and an appropriate non-cacheable policy through the adapter/response, and verify incremental delivery. Stop producing events after a stream error; do not switch response formats.

## Redirects and CSP

The Rust SDK's [ExecuteScript](https://github.com/starfederation/datastar-rust/blob/main/src/execute_script.rs) helper emits a script through an element patch. It is not a special navigation response, and CSP may block it. Use the app's existing navigation helper when available. A fetch 303 does not inherently navigate the browser's top-level page; plain form submission does.

Prefer HTML/signals unless an imperative action is necessary. For script-based navigation, use a server-chosen safe destination, serialize values rather than splice strings into code, and verify execution under the actual CSP. If using nonce-based execution, wire page/runtime/script nonces together; do not add `unsafe-inline` as a shortcut. See [Datastar security/CSP](https://data-star.dev/reference/security).

## Long-lived streams only when needed

Ordinary mutations emit finite events and end. Live feeds use an authenticated read stream and independent short write requests. Never retain a database transaction, pooled connection, or lock for a browser connection's lifetime.

- Let the framework poll an owned stream. If background producers are necessary, use bounded channels and explicit cancellation/drop cleanup. Dropping a Tokio `JoinHandle` alone does not cancel its task.
- Keep related events ordered through one stream/event loop. Bound buffered updates; define a resnapshot policy if a broadcast receiver lags or events are dropped.
- Scope subscriptions and every read to the authorized user/tenant. Define how access is revoked on logout or membership changes; authenticate every reconnect.
- Check the installed browser's cancellation/visibility options. Keep a stream initiator stable across patches and clean up subscriptions when it is removed.
- Disable retries for non-idempotent writes. Request cancellation and disabled buttons do not ensure exactly-once writes; use service-level idempotency when duplicate effects matter.
- Reconnect with an authoritative snapshot or an explicit replay contract. SSE IDs alone do not implement replay or prevent duplicate appends.
- Release receivers, timers, and tasks on disconnect. Where needed, use `tokio::select!` with cancellation and updates. Never hold a blocking mutex guard across `.await`.
- Scope timeout exceptions to live routes. Verify streaming through compression, reverse proxies, and buffering middleware. Configure a supported heartbeat/keep-alive policy and check actual flushing.
- Avoid one persistent connection per row/widget. Check client-facing HTTP/2 and connection limits. Datastar uses fetch streaming; native `EventSource` reconnection examples are not its API. See [MDN SSE guidance](https://developer.mozilla.org/en-US/docs/Web/API/Server-sent_events/Using_server-sent_events).
