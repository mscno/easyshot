---
name: datastar
description: Build, extend, debug, or review Datastar web interactions backed by Rust. Use for server-rendered templates, reactive data attributes, native forms, HTML patches, signals, and Rust SSE responses.
---

# Datastar web development

Build Billit pages and private HTML/SSE interactions with Topcoat SSR and its Datastar integration. Tokio runs the async role; Axum owns machine-facing HTTP APIs. Both adapters call the same application services directly. Follow [AGENTS.md](../../../AGENTS.md), [Rust architecture](../../../docs/rust-architecture.md), and the [API contract](../../../docs/api/contract.md). Imported and reviewed from Softbody Studio on 2026-10-03; no runtime or Rust dependency is installed by this skill.

## Start with the installed implementation

- Read relevant handlers, templates, response helpers, and middleware before changing an interaction. Billit specifies Topcoat, Datastar and Rocket, but has no Rust workspace or pinned browser runtime yet. Read the actual implementation as it lands; `mvpviz/` is a prototype, not the production stack.
- Check `Cargo.toml`, `Cargo.lock`, and the browser bundle's banner or asset configuration. Browser and Rust SDK versions are independent. Do not transfer the Go starter's dependency pins or assume its assets are installed here.
- Use one runtime loaded by the layout. Check documentation against the installed bundle/SDK before adopting examples; do not upgrade dependencies as a side effect of a feature.
- For forms, signals, and patch composition, read [Web patterns](references/web-patterns.md).
- For request decoding, streaming, redirects, or connection failures, read [Rust SDK and streaming](references/rust-sdk.md).
- For upstream rationale or unfamiliar features, use [Research sources](references/sources.md).

Use [Rocket](../datastar-rocket/SKILL.md) for reusable browser custom elements. Its combined bundle includes Datastar; disable Topcoat reactive/shard ownership of the same DOM. Use [Datastar Pro](../datastar-pro/SKILL.md) only for features verified in an available Pro runtime. Application modules must import from the same runtime URL as the layout.

## Billit interaction boundary

`/dashboard/*` renders operator pages, `/ui/*` serves private HTML/SSE, and `/portal/*` binds customer identity. They call the same application commands as `/v1/*`. Keep tenant, environment and customer authorization on the server. Never put credentials or permission decisions in signals.

Amounts and ledger identifiers cross browser/JSON boundaries as exact strings; avoid JavaScript Number conversions. A durable `202`/pending operation is not financial success. Show completion only from the finalized application result. Disable automatic mutation retries and reuse the application's idempotency identity when an explicit retry is needed. SSE reconnects query current state; they never repeat a payment or reservation command. Disconnecting a page does not cancel accepted work.

Follow the architecture's CSP and stream limits. Verify the selected runtime supports the intended nonce/expression mode; do not weaken CSP to make a widget work. UI patches are not the durable public event feed.

## Choose the simplest interaction

Keep persisted data and authorization decisions in application/domain services. Send HTML describing current state and available actions. Use signals for transient interaction state and inputs that need reactivity. Avoid duplicating domain objects into a browser store. Prefer a pending indicator until the server confirms a mutation. See [The Tao of Datastar](https://data-star.dev/guide/the_tao_of_datastar).

| Need | Approach |
| --- | --- |
| Navigate to another resource | Ordinary link and full-page response |
| Authentication flows | Native HTML form and full-page response |
| Create, edit, delete | Native POST form enhanced with Datastar; SSE or plain-form 303 response |
| Refresh a card or results region | Render the shared component and patch its explicit ID |
| Toggle a disclosure | Native `details` first; signal when extra interaction requires it |
| Input preview or live search | Small signals or named controls, explicit triggers, bounded requests |
| Live updates from other clients/jobs | Scoped read stream when the feature needs one |

Reuse the chosen Rust template engine or component system for pages and fragments. Extract expression helpers when repetition merits it; encapsulate custom JavaScript behind arguments and DOM events. See [Datastar reuse guidance](https://data-star.dev/how_tos/keep_datastar_code_dry).

## Implement within the HTTP boundary

1. Use the existing Rust state/dependency pattern to access application services. Parse transport input in handlers; leave use cases, transactions, and audit writes to services. Preserve established module boundaries.
2. Use the project's session middleware and permission checks. Hiding a control is presentation; services must still authorize. Never use client signals, IDs, or `Datastar-Request` as proof of identity or tenancy.
3. Render full pages and patches from the same components. Give every patch target a stable, unique, selector-safe ID that exists in the initial page. Select targets explicitly.
4. Authenticate, validate inputs, complete successful writes, and render essential fragments before returning SSE. Negotiate enhanced responses using the actual Datastar request contract; preserve native form success as 303. Mutation streams contain relevant fragments, signals, and feedback.
5. Map typed Rust errors to safe responses through shared response helpers. Correctable form failures retain safe attempted values and show field errors; plain forms receive an appropriate error page/status. Open create/add disclosures on failure; close and clear them on success. Do not refill secrets.
6. Propagate unexpected failures with `Result` and report them once at the handling boundary using the project's logger. Stop a response sequence after a stream failure. Treat expected disconnects/cancellation as lifecycle events; never send raw internal error text to clients.

## Browser state and executable content

- Prefer named native controls for ordinary forms. Enhanced form actions explicitly select form encoding and disable retries for writes. With Billit's pinned Datastar 1.0.2, set both `retry: 'never'` and `retryMaxCount: 0`: its network-error path otherwise retries despite `retry: 'never'`. Verify one attempt on an interrupted request in a real browser.
- Signals share a page store. Use feature/instance names to prevent collisions. An underscore prefix excludes a signal from default requests; it does not make the value private.
- Keep expressions trusted code. Put user data in escaped template text/attributes or safely serialized data, never concatenated expression source. HTML attribute escaping alone does not make JavaScript safe. Do not mark untrusted content as raw HTML or treat `data-ignore` as sanitization. See [Datastar security](https://data-star.dev/reference/security).
- Preserve cross-origin/CSRF protection, cookie policy, and CSP. Check the installed runtime's expression evaluation mode. Expression evaluation and inline script elements have different CSP requirements; consult the Rust reference before redirects or script patches.
- Use semantic links, buttons, labels, and keyboard-operable controls. Include a stable status/live region before patching routine messages. Test retained input and focus after morphing. See [MDN live regions](https://developer.mozilla.org/en-US/docs/Web/Accessibility/ARIA/Guides/Live_regions).

## Verify the changed behavior

- Follow the integration-first cadence in [AGENTS.md](../../../AGENTS.md): focused behavior checks during development and periodic green checkpoints, without full gates on every commit. Once Cargo exists, use targeted integration suites and formatting/build checks appropriate to the change.
- Exercise navigation, enhanced submission, and plain-form fallback. Check success, validation failure, denied access, and expired sessions as relevant.
- Meaningful handler tests check real auth behavior, SSE content type, event selector/mode, safe errors, and persisted outcomes using the project's HTTP test conventions.
- Browser verification is needed for reactive expressions, morph/focus behavior, redirects, and widgets: inspect console/CSP errors, actual request payloads, and DOM changes. HTTP tests do not prove JavaScript ran.
- For stream changes, exercise disconnect/reconnect and confirm subscriptions and background tasks end. Do not reset databases merely to validate a UI change.
