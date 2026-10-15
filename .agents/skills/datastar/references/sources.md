# Sources and maintenance

Links for checking behavior when requirements or the pinned versions change. Pins: Datastar v1.0.4 + Rocket beta.2 bundle (`server/static/datastar-rocket-1.0.4.js`), Topcoat 0.10 with the `datastar` feature (`server/Cargo.toml`, `Cargo.lock`).

## Datastar

- [Getting started](https://data-star.dev/guide/getting_started), [The Tao of Datastar](https://data-star.dev/guide/the_tao_of_datastar): state ownership, morphing, read streams.
- [Reactive signals](https://data-star.dev/guide/reactive_signals), [expressions](https://data-star.dev/guide/datastar_expressions), [backend requests](https://data-star.dev/guide/backend_requests).
- [Attributes](https://data-star.dev/reference/attributes) and [actions](https://data-star.dev/reference/actions): check whether a feature is Pro (not installed).
- [SSE events](https://data-star.dev/reference/sse_events), [security](https://data-star.dev/reference/security), [keep code DRY](https://data-star.dev/how_tos/keep_datastar_code_dry), [SSE connections closing](https://data-star.dev/how_tos/prevent_sse_connections_closing).
- [Rocket](https://data-star.dev/reference/rocket).

## Rust side

- Topcoat: [docs.rs 0.10](https://docs.rs/topcoat/0.10.0/topcoat/), its [Datastar module](https://docs.rs/topcoat/0.10.0/topcoat/datastar/index.html), and the unpacked crate sources under `~/.cargo/registry/src/*/topcoat-*-0.10.0`.
- [datastar-rust](https://github.com/starfederation/datastar-rust): protocol reference only.
- [MDN server-sent events](https://developer.mozilla.org/en-US/docs/Web/API/Server-sent_events/Using_server-sent_events), [ARIA live regions](https://developer.mozilla.org/en-US/docs/Web/Accessibility/ARIA/Guides/Live_regions).

## Local sources of truth

- `AGENTS.md`, `server/README.md` (architecture, RLS, endpoints, pins).
- `server/src/web/*` (pages, CSP, sessions), `server/src/video/*` (scope, live, service), `server/static/app.js` (Rocket components).
- `server/tests/web.rs`, `server/tests/rls.rs`: HTTP and database-level behavior. They cannot prove JavaScript ran; use a browser for that.

## Upgrading the bundle

Download the official release file, keep its license banner, store it under a new versioned name, update `web::assets::DATASTAR`, the sha256 in `assets.rs` and `server/README.md`, and the import in `static/app.js`. Recheck form encoding and retries, attribute syntax, morph identity, Rocket APIs used by `<easyshot-player>`, CSP, and stream reconnects in a browser.
