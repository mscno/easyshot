# Component integration

Read this when designing or implementing a Rocket widget. The recommendations below adapt browser component boundaries to this repository; recheck the selected runtime release before relying on version-specific APIs.

## Rocket API orientation

Import `rocket` from the exact runtime URL used by the layout (Billit selects the combined `datastar-rocket.js`; inspect the actual served URL); register a hyphenated tag. Public `props` use codecs. Use `$$` for instance state, `$$name` in markup, and `action(name, fn)` for local actions. Global `$` is shared page state.

| Hook | Responsibility |
| --- | --- |
| `setup` | State and behavior before rendered refs exist |
| `onFirstRender` | DOM/ref-dependent initialization |
| `render` | Return `html`/`svg` output; avoid resource allocation |
| `observeProps` | React to public prop changes |
| `cleanup(fn)` in setup context | Register release of timers, subscriptions and resources on disconnect |

Use string codecs for Billit amounts and ledger IDs, and keep financial validation on the server. Props are not local signals. `renderOnPropChange` defaults to enabled; disable selectively for imperative widgets with explicit synchronization. Default DOM mode is open shadow; `light` shares page styling. Consult the reference for codecs, slots, host accessors, scoping, and conditional/loop syntax. [Rocket API](https://data-star.dev/reference/rocket).

## Choose ownership explicitly

Prefer a server-rendered host whose attributes describe a small view model. Keep sensitive values out of reflected attributes and browser stores. The host's events should describe user intent, such as a proposed selection, and leave persistence to the page.

| Situation in this app | Suggested design decision |
| --- | --- |
| Existing form with a richer input | Keep the form, named submission control, action, and handler; enhance the input |
| Repeated third-party chart/editor | Let the widget own its internal DOM and library instance |
| Server updates a read-only chart | Send a bounded view model; compare a normal server-rendered SVG first |
| Editable widget receives server updates | Define when server values replace a draft and how conflicts are shown |
| Purely visual component with no browser behavior | Keep it a server-rendered template component |

Test initial mount and later prop updates separately. A subscription to changes is not evidence that initialization happened. For charts, confirm data updates reach the existing chart object. For editors, do not recreate the library on every keystroke or unrelated server patch. Cancel pending asynchronous work and destroy the library instance when its host is removed.

## DOM and styling

Application styles do not automatically style content inside a shadow root. Choose light DOM when sharing those rules is intentional, or define component-local styles using the application's CSS tokens. Shadow DOM provides encapsulation, not a security boundary. [MDN shadow DOM](https://developer.mozilla.org/en-US/docs/Web/API/Web_components/Using_shadow_DOM).

For SSE, render the same stable host ID from Rust templates on page load and refresh. Test the selected boundary with outer and inner element patches; an HTTP selector does not reach arbitrary shadow internals. Communicate changes through host inputs/events. If a third-party subtree needs morph protection, scope it to the actual client-owned subtree and test removal as well as updates.

Keep component definitions in application modules loaded through the layout, not repeated inline script patches. Inspect the project's security middleware: expression evaluation and inline script execution have different CSP requirements. Preserve safe template escaping and serialized data; never assemble executable expression source from user strings.

## Events and forms

Define public event names and payloads before wiring the page. Use a DOM `CustomEvent` with a documented `detail` shape. Events originating inside a shadow tree need the appropriate `composed` and bubbling settings to reach page listeners. Prefer page listeners on the host over querying widget internals. [MDN event propagation](https://developer.mozilla.org/en-US/docs/Web/API/Event/composed).

A public `value` property or a Datastar signal binding does **not** automatically add a custom element's value to native `FormData`. This matters because form-encoded Datastar actions send a native form payload, not the signal store.

Prefer retaining a real, named input/select/textarea in the outer form and synchronizing it with the widget. This also gives the no-JavaScript path a usable control. Avoid duplicate names that accidentally submit both the fallback and another copy of the value. Confirm form reset, disabled behavior, and validation still work.

An alternative is a genuinely form-associated custom element using platform `ElementInternals`, including `setFormValue`, validity, reset, and disabled semantics. Verify the chosen Rocket release supports the required integration before choosing that path; do not assume `props.value` implements it. [MDN form association](https://developer.mozilla.org/en-US/docs/Web/API/ElementInternals), [submission values](https://developer.mozilla.org/en-US/docs/Web/API/ElementInternals/setFormValue).

For an event-to-form adapter, inspect the actual request body in a browser: change the widget, submit with Datastar, submit natively, and reset. Ensure the same intended domain input reaches the handler. Treat client event payloads as untrusted input.

## Source and local reading map

- [Rocket reference](https://data-star.dev/reference/rocket): exact API for the available version.
- [Datastar Pro](https://data-star.dev/pro): commercial terms when selecting a Pro runtime.
- [Datastar web skill](../../datastar/SKILL.md): request encoding, server rendering, signal and SSE rules already used here.
- The application's asset server and layout: runtime/module URLs and loading.
- Rust handlers, response helpers, and templates: native form enhancement and patch boundaries.
- Security/session middleware: CSP, CSRF/cross-origin protections, and authentication.

These lifecycle notes were inherited from the source Pro v1.0.3 documentation. Billit selects the current combined Datastar/Rocket distribution and must verify API behavior against its own pin. No runtime asset has been copied into this project. Test each new component in a browser against the actual chosen runtime; installation alone does not verify a widget.
