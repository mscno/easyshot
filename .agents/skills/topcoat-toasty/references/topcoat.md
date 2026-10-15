# Topcoat patterns

Baseline: Topcoat 0.10.0, researched 2026-10-14. Links to `main` explain upstream practice but may be newer than an installed release.

## Routing and responses

Prefer `module_router!()` at the route-tree root. It discovers compiled modules, not files: add Rust `mod` declarations. Descendant module names become kebab-case URL segments; handler function names do not set the URL. `_group` modules group layouts/layers without contributing URL segments. Declare typed dynamic segments with `module_param!` and read them with `path_param::<T>(cx)`.

`#[page]` serves GET by default; `#[route(POST)]` declares a mutation endpoint. Use a layout's `Slot<'_>` for nested page content. Absolute-path handlers require explicit registration or `.discover()`; module routing alone does not include them. Discovery also registers procedures and shards. Duplicate method/path registrations are errors to resolve, not routes to silently shadow.

Sources: [module routing](https://docs.rs/topcoat/0.10.0/topcoat/router/macro.module_router.html), [router](https://docs.rs/topcoat/0.10.0/topcoat/router/index.html).

Build internal URLs from handlers with `href!(handler, Param(value))`, passing parameter wrappers in path order. Render the returned `Href` directly in URL attributes; use `.resolve(cx)` when an API needs a string. Use the router's `see_other(...)` response for POST/Redirect/GET (303) after a successful native form submission.

Use typed `Form<Input>` from `router::content` for native forms, and map invalid input, missing records, and denied access to the appropriate response. Preserve the framework's origin checks for mutations; they do not replace authentication or record-level authorization.

Sources: [handler URLs](https://github.com/tokio-rs/topcoat/blob/main/docs/router/href.md), [upstream HTTP conventions](https://github.com/tokio-rs/topcoat/blob/main/llms.txt).

## Rendering

Write literal text in quotes and dynamic values as `(value)` inside `view!`. Keep fixed markup literal; interpolate numbers directly instead of allocating display strings. Use `#[component] async fn ... -> Result<impl View>` with named arguments, `#[default]` for optional props, `#[into]` for conversion, and `Child<'_>` for child content. Forward attributes with `attributes!`; compose conditional classes with `class!`.

Views capture by move and evaluate later. Components render concurrently; output remains in source order, execution does not. Resolve ordered effects before constructing the view. In lists containing stateful components, use `#[key(item.id)]`; stable HTML IDs additionally support DOM identity during reordering.

Use `disabled=(bool)` to include/omit a boolean attribute. ARIA enumerated values need strings such as `"true"` and `"false"`. Avoid unescaped rendering of untrusted data.

Sources: [view semantics](https://docs.rs/topcoat/0.10.0/topcoat/view/macro.view.html), [components](https://docs.rs/topcoat/0.10.0/topcoat/view/attr.component.html).

## Context, authentication, and sessions

Register shared values with `.app_context(value)` and borrow them through small application helpers around `app_context::<T>(cx)`. Types must match exactly; use newtypes for two values of the same underlying type. Required lookups panic when absent; use `try_*` for deliberately optional values. Clone `Cx` into tasks/streams that outlive the handler's borrowed context.

Build focused `current_user`, `require_auth`, and permission helpers taking `&Cx`, and call them from the code needing protection. Reserve router layers for work that wraps request handling. `#[memoize]` deduplicates reads and concurrent work within one request, returning borrowed results; `#[memoize(as_ref)]` borrows contents of `Option`/`Result`. Scoped bindings affect cache reuse; interior mutation does not invalidate cached reads. Re-read appropriately after a mutation instead of treating memoization as a live database view.

Sources: [context and guards](https://docs.rs/topcoat/0.10.0/topcoat/context/index.html), [app context](https://github.com/tokio-rs/topcoat/blob/main/docs/context/app_context.md), [memoization](https://docs.rs/topcoat/0.10.0/topcoat/context/attr.memoize.html).

Install `.cookies()` before cookie-backed `.sessions(SessionConfig::default())`. Topcoat manages session tokens; the application persists token hashes, user associations, and expiries. Store `TokenHash`, not raw tokens; reject expired records. Persist fresh sessions on login, update storage when refreshing/rotating, and delete stored sessions on logout. Retain secure cookie defaults unless the deployment requires a justified change.

Set cookies/session changes before the handler returns: streaming work cannot update sealed response headers. For signed/private cookies, persist the same cryptographic key across restarts and instances. `CookieStore` mutations only queue a cookie when committed.

Sources: [sessions](https://docs.rs/topcoat/0.10.0/topcoat/session/index.html), [cookies](https://docs.rs/topcoat/0.10.0/topcoat/cookie/index.html).

## Native runtime and endpoint boundaries

Include `topcoat::runtime::script()` in the document head, load assets, and install `.runtime()` after application layers. Register shards/procedures through `.discover()` or explicit `.route(...)` calls. These are separate setup steps.

`$(...)` uses a supported Rust/JavaScript vocabulary, not arbitrary Rust. Reads inside it update browser expressions; tracked signal reads in server Rust trigger server renders. Prefer a shard when only a bounded region needs server refresh. Validate restored values as client input.

Each `#[shard]` is directly reachable without page/layout guards. Check identity, permissions, and selected record ownership inside it. Its restored signals are also client input. Stable item IDs help preserve focus/state when lists change.

Each `#[procedure]` is an HTTP endpoint: authorize and validate inside it. Invoke procedures from browser-only async event handlers; evaluating such a call during server rendering panics. An outer `Err` fails the browser expression; return a supported result-as-data shape when the UI must inspect an expected failure.

Sources: [runtime setup and tracking](https://docs.rs/topcoat/0.10.0/topcoat/runtime/index.html), [shard guards](https://docs.rs/topcoat/0.10.0/topcoat/runtime/attr.shard.html), [procedures](https://docs.rs/topcoat/0.10.0/topcoat/runtime/attr.procedure.html).

## Assets and formatting

Use `asset!` handles in views and register `AssetBundle` on the router. `topcoat dev` builds and bundles assets; release workflows must bundle the release executable and deploy its matching asset directory. Missing bundle entries can panic. Keep binary and bundle from the same build.

Use `topcoat fmt` for macro bodies and `cargo fmt` for ordinary Rust, or the CLI's `--rustfmt` option when available. Use `--check` in validation. Set the Rust edition in `rustfmt.toml` when using the formatter's Rustfmt integration.

Sources: [assets](https://docs.rs/topcoat/0.10.0/topcoat/asset/index.html), [formatter](https://github.com/tokio-rs/topcoat/blob/main/docs/cli/fmt.md).
