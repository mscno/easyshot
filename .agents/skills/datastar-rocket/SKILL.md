---
name: datastar-rocket
description: Evaluate, build, or review reusable browser widgets using Datastar Rocket in Billit's Rust/Topcoat web UI. Use for explicit Rocket work or complex custom elements with local state, lifecycle, or third-party widget integration; ordinary pages and forms use the datastar skill.
---

# Datastar Rocket widgets

Use Rocket selectively when a feature needs an encapsulated browser widget. Follow `AGENTS.md` when present and the existing [Datastar web skill](../datastar/SKILL.md) for Rust handlers, templates, forms, SSE, and domain boundaries.

## Decide whether it helps

Plausible uses are an editor wrapper, interactive chart, or a repeated compound input whose browser behavior has become difficult to maintain in templates. Explain the concrete reduction in duplicated behavior or lifecycle code before introducing a component. Ordinary CRUD, authentication forms, disclosures, and pagination generally have simpler native/template implementations.

Imported from Softbody Studio and reviewed for Billit on 2026-10-03. Earlier notes originated in the Go starter's Pro v1.0.3 bundle. Current upstream distributes a separate `datastar-rocket.js` that includes Datastar; Rocket does not by itself require the historical Pro asset. No browser asset is installed by this skill. Preserve the selected asset's actual license. Rocket's APIs and distribution can change between releases; inspect the actual module exports before using examples. Datastar Rocket browser widgets are unrelated to the Rust Rocket web framework.

## Use the selected runtime

Pin and self-host the combined `datastar-rocket.js` and matching declarations. Check actual exports before adopting examples. Load that module once through Topcoat's layout and import from the same URL; do not also load a core/Pro copy. Disable Topcoat's reactive/shard runtime on these pages. See [Billit architecture](../../../docs/rust-architecture.md).

Read [Component integration](references/integration.md) for lifecycle, forms, events, and morph boundaries. Use [Datastar Pro](../datastar-pro/SKILL.md) for Pro attributes/actions. Check the actual module exports and [Rocket reference](https://data-star.dev/reference/rocket) for version-specific APIs.

## Keep a narrow component contract

Write down the host tag and ID, input values, output events, DOM owner, form submission value, and fallback before implementation. Use `billit-` tags and test two instances on one page. Money and ledger ID props are exact strings, never the numeric codec. Operation widgets distinguish accepted/pending from finalized success and refresh after reconnect without reissuing commands.

The Rust application service remains authoritative for persisted state, tenancy, validation, permissions, audit, and jobs. A component may propose an edit; the surrounding page submits it using native form encoding and the existing SSE/plain-form response path. It may not declare success before the server confirms it. Browser state and codec normalization do not enforce domain invariants.

Have the Rust template engine render the host and server-controlled values. Choose a stable patch boundary around the widget and verify that the chosen morph actually updates its public inputs without discarding an active editor or selection. Avoid globally ignoring morphs: permission changes and server corrections still need to reach the UI.

## Verify before claiming integration works

- Follow [AGENTS.md](../../../AGENTS.md) for focused integration checks and periodic green checkpoints; full gates are not required at every commit.
- With the selected runtime, exercise two instances, input changes from SSE, repeated patches, removal/reinsertion, cancellation, and cleanup. Check the console for missing exports, duplicate registrations, expression failures, and CSP violations.
- Verify keyboard access, accessible labels, retained focus, native form values, validation failure, and a useful no-JavaScript fallback where the page requires it.
- Verify existing non-Rocket Datastar actions still function with the selected bundle. HTTP tests alone cannot validate a custom element's lifecycle or rendered DOM.
- State whether verification covered documentation, syntax, mocked code, or a real browser/runtime. Missing runtime access limits runtime validation, not the ability to write the design or skill.

Historical examples came from Pro v1.0.3. The upstream combined Rocket distribution was reviewed on 2026-10-03; qualify the actual Billit pin in a browser before claiming runtime integration.
