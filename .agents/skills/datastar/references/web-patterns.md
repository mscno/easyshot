# Web patterns

These examples are HTML patterns for Topcoat SSR; SDK builder names below are protocol illustrations, not a requirement to add a second Rust SDK. Render dynamic values with context-appropriate escaping; identifiers and routes are illustrative.

## Forms are the default write contract

Keep submission on the form so Enter, native validation, and submit buttons share one path:

```html
<form id="item-rename" method="post" action="/items/example"
      data-on:submit="@post('/items/example', {contentType: 'form', retry: 'never'})"
      data-indicator:_item-saving>
  <label for="item-name">Name</label>
  <input id="item-name" name="name" value="Example" required />
  <button type="submit" data-attr:disabled="$_itemSaving">Save</button>
</form>
```

Replace the route/value with handler-chosen, escaped template values. Repeated forms need instance-specific IDs and indicator signals. Keep any CSRF token required by the backend in the native form payload.

Form actions explicitly select `contentType: 'form'` and `retry: 'never'`. Named controls are the payload; form encoding does not send signals. Use the framework's bounded form extractor and typed input DTO. Do not trim values where whitespace matters, including passwords. Preserve native `method`/`action` for the no-JavaScript path. See [backend action encoding](https://data-star.dev/reference/actions#backend-actions).

Use existing application expression helpers when present rather than copying action strings throughout templates. This project does not inherit the Go starter's `hyper` helpers or structural checker.

Wrap create/add forms in native `details` when useful. Patch the enclosing box open on failure with safe attempted values; close and clear it on success. Other affected regions and a status message can be patched in the same response. Plain-form success returns 303.

For uploads, use a named file input with `enctype="multipart/form-data"` and a size-limited multipart parser. Release temporary resources. File signal binding creates base64 data and is not a drop-in replacement for a native upload workflow. See [file binding](https://data-star.dev/reference/attributes#data-bind).

## Signals and event expressions

- Current syntax uses `data-on:click`, `data-bind:query`, `data-attr:disabled`, and `$query`; check the installed runtime before copying old tutorial syntax.
- Attribute keys use kebab case: `data-indicator:_item-saving` exposes `$_itemSaving`. Value syntax such as `data-bind="search.query"` avoids attribute-name casing issues.
- Initialize types intentionally. Use `data-computed` for derived values and `data-effect` for side effects. Avoid effects that read and write the same signal.
- Defaults should not erase drafts on remount. When supported, use `data-signals__ifmissing` or `PatchSignals::only_if_missing(true)`; reset explicitly after success.
- Signal deletion uses `null`; nested objects merge while arrays replace. Rust reset DTOs must serialize `false`, `0`, and empty strings when intended; avoid `skip_serializing_if` that omits those resets. See [signal patching](https://data-star.dev/guide/reactive_signals).

A GET form can provide native search with debounced enhancement:

```html
<form id="item-search" method="get" action="/items/search"
      data-on:submit="@get('/items/search', {contentType: 'form', retry: 'never'})">
  <label for="item-query">Search items</label>
  <input id="item-query" name="q" type="search"
         data-on:input__debounce.300ms="@get('/items/search', {contentType: 'form', retry: 'never'})" />
  <button type="submit">Search</button>
</form>
```

The Rust handler reads `q`, renders a full page for navigation, and patches the existing results region for Datastar. If reactive input is required, use `data-bind:search.query` and decode the nested JSON contract as described in [Rust SDK](rust-sdk.md). Debounce explicit events; broad watchers can loop when responses update signals. Use `evt` for the current event and `el` for the bound element. See [expression semantics](https://data-star.dev/guide/datastar_expressions).

## Patch composition

| Operation | Event construction | Rendered content |
| --- | --- | --- |
| Morph a card/form | `PatchElements::new(html).selector("#item")` | Root retains `id="item"` |
| Update a list body | Same builder with `ElementPatchMode::Inner` | Children only |
| Append a page | Same builder with `ElementPatchMode::Append` | Children with unique row IDs |
| Remove a row | `PatchElements::new_remove("#item")` | No replacement markup |

Use the selected SDK adapter to turn builders into framework SSE events. Default outer and inner modes morph; replace discards the target. Stable IDs preserve identity. Choose the smallest coherent component expressing changed state. See [patch modes](https://data-star.dev/reference/sse_events).

Appending is not idempotent: retries/replayed pages can duplicate rows. Refresh the list region when simpler, or manage cursors/deduplication. Remove empty-state markup when inserting the first result and update pagination. Include real next-page links when navigation must work without JavaScript.

For editors/charts, define the client-owned subtree and integrate through properties/events. Use `data-ignore-morph` only for that boundary, keeping it in current and incoming markup. Clean up on removal; do not shield server-owned permissions/content from updates. See [widget integration](https://data-star.dev/guide/datastar_expressions#web-components).
