---
name: datastar-pro
description: Decide whether and how to use Datastar Pro attributes or actions (validation, persistence, URL state, media queries, animation, resize, scrolling, view transitions, @clipboard/@intl/@fit) in Easyshot's web UI. Datastar Pro is NOT installed; use alongside the datastar skill.
---

# Datastar Pro in Easyshot

**Datastar Pro is not installed.** Easyshot ships one self-hosted bundle, `server/static/datastar-rocket-1.0.4.js` (Datastar v1.0.4 + Rocket beta.2, MIT). Pro attributes and actions in markup are silently inert with that bundle. Follow the [datastar skill](../datastar/SKILL.md) for everything else.

## Before using any Pro feature

1. Prefer what already works: native HTML/CSS (`<details>`, media queries, `prefers-reduced-motion`), server-rendered state, a small module in `server/static/app.js`, or a Rocket component ([datastar-rocket](../datastar-rocket/SKILL.md)).
2. If Pro is still worth it, the user must decide to buy and supply a licensed Pro bundle. Do not download, copy or reference a Pro bundle from another project.
3. Installing it means replacing the single runtime (one Datastar per page): new versioned file in `server/static/`, its license banner preserved, `web::assets::DATASTAR`, the sha256 and the `app.js` import updated, and the whole site re-verified in a browser (forms, live streams, `<easyshot-player>`).
4. Check the exact attribute/action behavior against that bundle's version, not these notes.

## What Pro offers, and Easyshot-specific cautions

| Attribute/action | Useful for | Easyshot caution |
| --- | --- | --- |
| `data-custom-validity` | Cross-field validation (password confirmation on sign-up) | Empty string means valid; the server still validates |
| `data-persist` | Harmless UI preferences | Explicit allowlist and a versioned key; never identity, tokens, video data or permissions |
| `data-query-string`, `data-replace-url` | Shareable filters (library search) | The Rust handler must render the same state from the URL on direct navigation |
| `data-match-media` | Behavior tied to a media query | Prefer CSS when only styling changes |
| `data-on-resize`, `data-on-raf` | Measuring, frame work | No network or heavy work per frame; avoid resize/write loops |
| `data-animate`, `data-view-transition` | Motion | Respect reduced motion; keep updates working without animation |
| `data-scroll-into-view` | Revealing new content | Only on user intent; do not steal focus on live patches |
| `@clipboard` | Copy link | The existing `[data-copy]` handler in `app.js` awaits the Clipboard API and handles failure; keep it |
| `@intl`, `@fit` | Formatting, range mapping | Durations, counts and dates are rendered server-side today; keep one formatter |

Syntax and behavior notes for these attributes, from a Pro v1.0.3 bundle seen elsewhere: [attribute patterns](references/attributes.md). Treat them as orientation only.

## Constraints that do not change with Pro

- Writes stay native forms enhanced with `contentType: 'form'`, `retry: 'never'`, `retryMaxCount: 0`.
- Persisted or URL state is untrusted input when it returns to the server.
- CSP stays `script-src 'self' 'unsafe-eval'`; no inline scripts.
- Live updates still come from the page's SSE stream; Pro features must survive morph patches of their region.
- Verify in a real browser: initialization order, reload with stored/URL state, back/forward, reduced motion, focus.
