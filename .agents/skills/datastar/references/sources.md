# Research sources and maintenance

Imported from Softbody Studio and reviewed for Billit on 2026-10-03. The source was adapted from the Go starter; historical Pro notes were reviewed there on 2026-09-15. This is a repository-specific synthesis, not a copy of the upstream manuals. Links are for checking behavior when requirements or installed versions change.

## Official Datastar guidance

- [Getting started](https://data-star.dev/guide/getting_started): installation, self-hosting, backend-rendered element patches.
- [The Tao of Datastar](https://data-star.dev/guide/the_tao_of_datastar): state ownership, morphing, navigation, pending indicators, optional live read streams.
- [Reactive signals](https://data-star.dev/guide/reactive_signals): binding and signal patching.
- [Expressions](https://data-star.dev/guide/datastar_expressions): expression evaluation, `evt`/`el`, and custom widget integration.
- [Backend requests](https://data-star.dev/guide/backend_requests): signal transport and nesting.
- [Attributes](https://data-star.dev/reference/attributes): exact syntax and modifiers; check whether a feature is marked Pro or absent from the vendored bundle.
- [Actions](https://data-star.dev/reference/actions): form versus JSON encoding, retries, cancellation, and content types.
- [SSE events](https://data-star.dev/reference/sse_events): element modes and signal event fields.
- [Security](https://data-star.dev/reference/security): executable attributes, untrusted inputs, and current CSP guidance.
- [Keep Datastar code DRY](https://data-star.dev/how_tos/keep_datastar_code_dry): template reuse.
- [Prevent SSE connections closing](https://data-star.dev/how_tos/prevent_sse_connections_closing): background tab behavior.
- [Backend redirects](https://data-star.dev/how_tos/redirect_the_page_from_the_backend): SDK redirects; also inspect the pinned implementation and local CSP.

## SDK and complementary primary resources

- [Official Rust SDK](https://github.com/starfederation/datastar-rust) and [examples](https://github.com/starfederation/datastar-rust/tree/main/examples): event builders and framework adapters. Read the installed release selected by `Cargo.lock`; upstream main may differ.
- [Axum SSE](https://docs.rs/axum/latest/axum/response/sse/index.html): framework-owned streaming when Axum is the selected backend.
- The selected Rust template engine documentation: escaping, safe HTML, reusable fragments, and any code generation.
- [Hypermedia Systems: Client Side Scripting](https://hypermedia.systems/client-side-scripting/): use scripting to support the hypermedia interaction model and encapsulate widgets. Its htmx examples are architectural references, not Datastar syntax.
- [MDN: Using server-sent events](https://developer.mozilla.org/en-US/docs/Web/API/Server-sent_events/Using_server-sent_events): framing, transport limits, and idle connections. Its native `EventSource` API differs from Datastar fetch actions.
- [MDN: ARIA live regions](https://developer.mozilla.org/en-US/docs/Web/Accessibility/ARIA/Guides/Live_regions) and [status role](https://developer.mozilla.org/en-US/docs/Web/Accessibility/ARIA/Reference/Roles/status_role): announcing updates without stealing focus.

## Local sources of truth

Billit has architecture/specification documents and local data tooling, with no Cargo workspace or vendored browser runtime yet. Start with `docs/rust-architecture.md`, `docs/modular-monolith.md`, `docs/api/contract.md`, and `docs/development-workflow.md`. Topcoat is the selected HTTP/SSR/Datastar boundary; inspect its pinned integration as implementation lands. Do not copy Softbody Studio crate names, engine dependencies, database model, toolchain pins or asset paths.

- `AGENTS.md`, when present: project conventions and checks.
- `Cargo.toml` and `Cargo.lock`: Rust SDK/framework versions and enabled features.
- The browser bundle banner or asset configuration: installed Datastar version and runtime URL.
- Rust HTTP handlers and shared response helpers: forms, decoding, 303/SSE negotiation, patch composition, and errors.
- Templates/components and layout: shell, patch IDs, escaped values, status messages, and module loading.
- Session/security middleware: authentication, authorization, CSRF/cross-origin protections, and CSP.
- Live stream handlers: cancellation, subscriptions, backpressure, keep-alive, and timeouts.
- HTTP integration tests and browser tests: transport/persistence versus actual JavaScript execution.

On upgrades, recheck browser/SDK request encoding together, attributes/options, morph identity, retry/cancellation, script execution under CSP, and stream cleanup. Update version notes/examples only after verifying behavior.
