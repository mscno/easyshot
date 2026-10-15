# Pro attribute patterns (orientation only)

**Not installed in Easyshot.** These notes describe a Datastar Pro v1.0.3 bundle examined in another project. Easyshot's bundle (Datastar v1.0.4 + Rocket beta.2) does not include them. If a licensed Pro bundle is ever installed, re-check each behavior against it and the [upstream reference](https://data-star.dev/reference/attributes#pro-attributes). Examples are small patterns, not a reason to add plugins to a page.

## Validation and media

```html
<input name="code" data-bind:code />
<input name="confirmation" data-bind:confirmation
       data-custom-validity="$code === $confirmation ? '' : 'Codes must match.'" />
<div data-match-media:_reduce-motion="(prefers-reduced-motion: reduce)"></div>
```

`data-custom-validity` accepts a string expression on an input, select, or textarea. Clear the message when valid; do not return a boolean. Retain native constraints and domain validation. Avoid persisting sensitive confirmation fields if adapting this to an account form.

`data-match-media` needs a signal key and media-query value. `_reduce-motion` creates `$_reduceMotion`; it is excluded from normal signal requests. Use CSS media queries alone when no JavaScript behavior depends on the result. The plugin listens for changes and removes its signal/listener on cleanup, so do not share its key with an unrelated owner.

## Animation, frames, and resize

```html
<circle r="10" data-animate:r__duration.250ms="$radius"></circle>
<div data-on-raf__throttle.100ms="$_elapsed = performance.now() - $_started"></div>
<div data-on-resize__debounce.150ms="$_width = el.getBoundingClientRect().width"></div>
```

Initialize referenced signals first. `data-animate` interpolates numeric attribute values, including values with matching unit suffixes. It does not interpolate arbitrary CSS strings or colors. The source v1.0.3 implementation supports `__duration`, `__delay`, `__ease`, `__loop`, and `__pingpong`; verify the exact easing name rather than assuming CSS easing syntax. Prefer one animated attribute per element and test interruption/removal. For reduced motion, choose a nonanimated rendering path; do not assume this plugin handles the preference automatically.

Use `performance.now()` for elapsed time instead of counting frames. Keep frame callbacks cheap. Resize callbacks receive no special dimensions object: measure `el` only when needed and avoid changing its own dimensions in a loop. Use throttling/debouncing proportional to the actual interaction. Test removal and reinsertion for resource leaks.

## Persistence

```html
<div data-signals:prefs__ifmissing="{compact: false}"
     data-persist:easyshot-prefs-v1="{include: /^prefs\.compact$/}">
</div>
```

The suffix chooses the storage key; `__session` selects sessionStorage instead of localStorage. Prefer a dedicated, versioned application key when the schema evolves. The value is a filter object with regexes, not the data to save. Avoid bare `data-persist`, which can capture unrelated page signals.

In the v1.0.3 bundle, initialization merges the whole stored object before the filter is applied to subsequent writes. A narrower filter therefore does not sanitize an old storage entry. Use a new key or clear/migrate it when reducing the persisted schema. Stored values are untrusted and can outlive the current login. Handle unavailable storage gracefully for required user flows; preferences must not become an authentication dependency.

## Query strings and history

```html
<div data-signals:search="{q: '', page: 1}"
     data-query-string="{include: /^search\.(q|page)$/}">
</div>
```

Only initialized, selected signals can be restored. This example uses dotted URL keys such as `search.q`; the Rust handler must parse those keys for direct navigation. The plugin coerces boolean and numeric-looking strings, so test leading-zero identifiers and any text field where that conversion would be surprising.

Default changes replace history. `__history` pushes entries and listens to popstate; use it for meaningful navigation states, not every keystroke. `__filter` omits falsy values in v1.0.3, including `false` and `0`, not only empty text. The plugin rebuilds the query string from its selected signals: unrelated query parameters and hash fragments may be lost. Use it only when it owns the page query contract; otherwise construct a URL that deliberately preserves required parameters.

Removing a parameter through history does not necessarily reset the corresponding signal: the source v1.0.3 restore path only writes keys present in the URL. Test back/forward with missing/default filters and implement the intended reset or choose ordinary server navigation.

```html
<div data-replace-url="'/library?q=' + encodeURIComponent($query)"></div>
```

`data-replace-url` evaluates an expression and calls history replacement. It neither fetches nor navigates. Choose one owner for URL changes, preserve required parameters, and use ordinary links for resource navigation. Keep requested URLs same-origin and handler-chosen.

## Scrolling and transitions

```html
<section tabindex="-1" data-scroll-into-view__instant__vnearest></section>
<article data-view-transition="'library-item'"></article>
```

`data-scroll-into-view` takes no key or expression. It executes when applied, so unchanged attributes retained by a morph are not a promise to scroll again. `__smooth`, `__instant`, and `__auto` choose motion; horizontal/vertical alignment modifiers and `__focus` refine the behavior. Focus only when the user action merits it. Test actual tabindex behavior: the plugin may add a tabindex itself.

`data-view-transition` sets a transition name; it does not by itself start a transition. Use unique names for simultaneously rendered elements, and a separately supported trigger such as the SDK patch option or the core `__viewtransition` event modifier. Test the normal update path when the browser lacks View Transition support. Keep navigation working without animation.
