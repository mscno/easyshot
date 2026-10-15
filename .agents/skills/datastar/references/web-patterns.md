# Web patterns

HTML patterns for Topcoat `view!` pages in `server/src/web`. Look at `watch.rs` (`comment_form`, `reactions_region`) and `account.rs` (library item actions) for the house style before writing new markup.

## Forms are the default write contract

Keep submission on the form so Enter, native validation and submit buttons share one path:

```html
<form id="item-rename-{id}" method="post" action="/library/{id}/rename"
      data-on:submit="@post('/library/{id}/rename', {contentType: 'form', retry: 'never', retryMaxCount: 0})"
      data-indicator:_saving-{id}>
  <label for="title-{id}">Title</label>
  <input id="title-{id}" name="title" value="Demo" required maxlength="200">
  <button type="submit" data-attr:disabled="$_saving{Id}">Save</button>
</form>
```

- In `view!`, build the action string once in Rust (`format!`) from server-chosen values and interpolate it; never from user text.
- Named controls are the payload; form encoding sends no signals. Decode with Topcoat's `Form<Input>` into an explicit input struct; validate lengths; do not trim passwords.
- Keep native `method`/`action` so the no-JavaScript path works. Handlers check `datastar_request(cx)`: patches for Datastar, `see_other` (303) for plain posts.
- Repeated forms need per-instance ids and indicator signals.
- On failure, re-render the form region with field errors and safe attempted values; on success, replace it fresh (`ElementPatchMode::Replace` clears inputs) and patch the other affected regions in the same response.
- Uploads from the browser are not a current feature; media goes from the Mac app straight to S3 via presigned URLs.

## Signals and expressions

- Syntax for the pinned 1.0.4 bundle: `data-on:click`, `data-bind:query`, `data-attr:disabled`, `data-indicator:_x`, `$query`. Check before copying older tutorials.
- Attribute keys are kebab case: `data-indicator:_item-saving` exposes `$_itemSaving`.
- Signals share one page store: name them per feature/instance. Initialize types intentionally; avoid effects that read and write the same signal; keep drafts with `__ifmissing` where a remount could erase them.
- Signals are client state only: never identity, permissions, tokens or another user's data.
- Expressions are trusted code. User values go in escaped attributes/text, not expression source. `evt` is the event, `el` the element.

Live search (debounced GET that patches a results region):

```html
<form id="library-search" method="get" action="/library"
      data-on:submit="@get('/library', {contentType: 'form'})">
  <input id="library-q" name="q" type="search"
         data-on:input__debounce.300ms="@get('/library', {contentType: 'form'})">
</form>
```

The handler reads `q`, renders the full page for navigation and patches only the results region for Datastar requests.

## Patch composition

Topcoat's integration is `topcoat::datastar` (`PatchElements`, `ElementPatchMode`, `datastar_request`); `watch.rs` shows the helpers `patch` (morph by the root's id) and `fresh` (replace).

| Operation | Builder | Rendered content |
| --- | --- | --- |
| Morph a region | `PatchElements::new(html)` | Root carries the stable id |
| Replace (reset inputs) | `.mode(ElementPatchMode::Replace)` | Whole element |
| Inner/append | `.mode(ElementPatchMode::Inner / Append)` with `.selector("#id")` | Children with unique ids |
| Remove | `PatchElements::remove("#id")` | — |
| Signals | `PatchSignals::json(&dto)?`, `.only_if_missing(true)` | — |

Default modes morph; stable ids preserve identity, focus and video playback. Appends are not idempotent: prefer re-rendering a bounded list region. Remove empty-state markup when the first row arrives.

For widgets that own their subtree (the player), keep the server-rendered host stable and patch around it, or use `data-ignore-morph` only on the client-owned subtree; never to shield server-owned content or permissions.
