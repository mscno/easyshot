---
name: datastar-pro
description: Use Datastar Pro attributes and actions in Rust-rendered web UIs, including validation, persistence, URL state, media queries, animation, resize, scrolling, and transitions. Use alongside datastar for server interactions and datastar-rocket for custom components.
---

# Datastar Pro

Use Pro features only when the chosen Billit runtime actually supplies them. Billit selects a combined Datastar/Rocket bundle; that choice does not establish availability of every historical Pro plugin. Follow `AGENTS.md` when present and the [Datastar skill](../datastar/SKILL.md) for server-owned state, forms, SSE, and error handling. For custom elements use the [Rocket skill](../datastar-rocket/SKILL.md).

## Runtime provenance and integration

Imported from Softbody Studio on 2026-10-03. These historical browser patterns originated in `go-starter`, where a licensed **Datastar Pro v1.0.3** bundle was supplied. That asset has not been copied into this project, and copying these instructions does not install it. Check the selected local runtime and existing license context before implementation. Preserve any supplied commercial license banner; a repository license does not relicense the vendor asset.

The v1.0.3 notes below describe the source project's bundle, not an installed baseline here. Recheck them against the runtime actually chosen. Load one Datastar module from the application's layout and use its exact URL in application imports. For example, if served at that path:

```js
import { rocket } from '/static/datastar-pro.js'
```

Keep component definitions in external modules. Do not load another core/Pro copy, attach invented globals, or modify minified vendor code. Browser Pro features do not by themselves require a Rust SDK upgrade.

## Select an attribute

| Attribute | Useful for | Main design check |
| --- | --- | --- |
| `data-animate` | Numeric HTML/SVG attribute motion | Matching units and reduced motion |
| `data-custom-validity` | Cross-field browser validation | Empty string means valid; keep server validation |
| `data-match-media` | Behavior conditional on a media query | Prefer CSS for styling alone |
| `data-on-raf` | Work tied to animation frames | No network or expensive work every frame |
| `data-on-resize` | Measuring a widget after resize | Avoid resize/write feedback loops |
| `data-persist` | Remembering harmless UI preferences | Explicit signal allowlist and storage key |
| `data-query-string` | Shareable filters/search state | URL ownership, reload, and history behavior |
| `data-replace-url` | Updating the current history entry | This does not navigate or fetch |
| `data-scroll-into-view` | Bringing new content into view | No value; intentional scrolling and focus |
| `data-view-transition` | Naming an element for a transition | Unique names and separate transition trigger |

Read [Attribute patterns](references/attributes.md) for exact syntax, modifiers, and v1.0.3 behavior. Public references: [Pro attributes](https://data-star.dev/reference/attributes#pro-attributes), [Pro actions](https://data-star.dev/reference/actions#pro-actions). These implementation notes were checked against the source project's v1.0.3 bundle.

## Preserve the app's contracts

- Normal mutations remain named native forms enhanced with form-encoded Datastar actions and retries disabled. Pro validation or signal binding does not change form encoding or domain validation.
- Persist only explicitly chosen presentation preferences. Do not store credentials, account details, tenant data, or permission decisions in browser storage or the URL. Use distinct keys for preferences with different user/tenant scopes and remove obsolete scoped state on context changes.
- Decide whether server-rendered defaults, storage, or the URL wins during initialization. Declare the necessary signals before the plugin; do not rely on accidental DOM order or initialize them again after storage/URL restoration.
- Keep URL state readable by the Rust handler so direct navigation reproduces the page. Query synchronization is not a client router or a substitute for requesting updated HTML. Avoid watchers that repeatedly fetch after their own response patches signals.
- Keep expressions static and pass user values through escaped template attributes or serialized data. Check the actual CSP and runtime evaluation mode; inline script patches need separate CSP handling.
- Respect reduced motion and keyboard access. Focus a field after a correctable error when useful; do not move focus on every background update.

## Pro actions

`@fit(...)` maps a number between ranges; `@intl(...)` formats values using browser internationalization. Use them for presentation, leaving authoritative amounts and timestamps in the domain. Billit money remains an exact string: do not feed atomic amounts through a numeric formatter or JavaScript Number if precision could be lost. Check argument order and locale against the installed implementation.

`@clipboard(...)` requires browser clipboard availability. In v1.0.3 the action calls `navigator.clipboard.writeText` without returning its promise. If the UI must confirm successful copying or handle rejection, use an application module/Rocket action that awaits the native API; do not show success immediately after invoking `@clipboard`.

## Verify

Follow [AGENTS.md](../../../AGENTS.md): prefer integration checks, commit small changes, and run full checks at periodic green checkpoints rather than every commit. Follow the chosen template engine's source/generation workflow. Verify actual browser behavior under the page CSP: initialization order, input validity, patch/remount behavior, storage reload, URLs/back/forward, resize cleanup, motion preferences, and focus as relevant. Exercise both normal form submission and Datastar submission when enhancing forms. Use the project's Rust HTTP integration test conventions for transport checks; those tests cannot prove a browser plugin ran.

Browser notes were reviewed against the source project's Pro v1.0.3 bundle on 2026-09-15 and adapted for Rust on 2026-10-03. Verify them against the selected runtime before use.
