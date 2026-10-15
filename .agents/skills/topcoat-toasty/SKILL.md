---
name: topcoat-toasty
description: Build, debug, or review Rust web applications using Topcoat and optionally Toasty ORM. Use for Topcoat routing, SSR components, request context, forms, sessions, assets, signals, procedures, shards, and Toasty models, queries, transactions, or migrations.
---

# Topcoat and Toasty

Use Topcoat's server rendering and typed Rust APIs, with Toasty for persistence when the application selects it. Toasty is the ORM's name; requests may misspell it as toastry or tosty.

## Establish the implementation

- Read the target project's instructions, `Cargo.toml`, `Cargo.lock`, router construction, root layout, and relevant models before changing code. This workspace contains multiple projects; work in the project the user named.
- Match the installed crate versions and CLI. These notes were researched on 2026-10-14 against Topcoat 0.10.0 and Toasty 0.11.0 documentation. Both evolve: use versioned rustdoc and the corresponding source/examples before adopting APIs from `main` or `latest`.
- Preserve the application's architecture and database choice. Topcoat can work with other persistence libraries. This skill does not require replacing SQLx or moving business logic into templates. Apply shared business operations through the existing service boundary.
- Feature flags expose APIs; router builder calls install their services. Check both when diagnosing missing runtime, cookies, sessions, discovery, or assets.

## Choose the relevant guidance

- For routes, rendering, context, forms, sessions, assets, or native reactivity, read [Topcoat patterns](references/topcoat.md).
- For database initialization, model changes, queries, transactions, or schema evolution, read [Toasty persistence](references/toasty.md).
- For Datastar pages, retain the project's selected interaction model and use the available `datastar` skill for detailed attributes and SSE behavior. Consult [Topcoat's Datastar integration](https://docs.rs/topcoat/0.10.0/topcoat/datastar/index.html); do not assume another Rust SDK's builders are interchangeable. If combining runtimes, assign distinct DOM ownership and verify the boundary rather than letting both update the same region. That ownership rule is an integration recommendation, not a documented Topcoat restriction.

## Core decisions

- Prefer module routing for new Topcoat route trees. Compile child modules explicitly and use `href!` for internal links, form actions, and redirects. Keep existing explicit routing where the project already uses it.
- Build reusable markup as async `#[component]` functions. Rendering is lazy and concurrent: perform mutations and ordered effects before constructing the view. Keep dynamic content in escaped interpolation.
- Put request-wide reads and guards in composable functions accepting `&Cx`. Call authorization where protected data is read or changed, including independently reachable endpoints. Use `#[memoize]` for repeated request-local reads, with awareness of stale results after writes.
- Use browser signals for local UI state, shards for server-refreshed markup, and procedures for browser-triggered server operations. Validate client arguments and restored signals. A shard endpoint does not inherit its page/layout guards.
- Keep form input separate from persisted models. Validate editable fields and derive ownership/privilege fields on the server before explicitly building a Toasty create or update. Automatic safe model/form binding is not an API to assume; consult the matching release before using new integration features.

## Verify the changed behavior

Run the target project's established checks. For Rust implementation work, check compilation and relevant tests; run `cargo fmt` and `topcoat fmt --check` where supported, since Rustfmt alone does not format Topcoat macro bodies. For UI work, exercise the initial page and the actual form, procedure, shard, or SSE request in the browser, including invalid input and denied access. Verify asset requests and focus/state after updates. For persistence work, use an isolated database to check constraints, transaction rollback, and migrations appropriate to the change.

Do not add a sample app or dependencies merely to install this skill. Report what was verified and any version-specific uncertainty.
