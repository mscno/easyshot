---
name: datastar-rocket
description: Build, extend or review Datastar Rocket custom elements (easyshot-* tags such as <easyshot-player>) in Easyshot's Topcoat web UI. Use for encapsulated browser widgets with local state, lifecycle or media/third-party integration; ordinary pages and forms use the datastar skill.
---

# Rocket components in Easyshot

Rocket ships inside the single runtime `server/static/datastar-rocket-1.0.4.js` (Datastar v1.0.4 + Rocket beta.2, MIT). Components live in `server/static/app.js`, which imports `rocket` from that exact URL; the layout loads both. Datastar Rocket is unrelated to the Rust Rocket web framework. Follow the [datastar skill](../datastar/SKILL.md) for handlers, forms, patches and live streams.

## The existing component

`<easyshot-player>` (light DOM, no render function) wraps the server-rendered native `<video controls>` (which is also the no-JavaScript fallback). It:

- publishes playback time into `[data-player-time]` inputs and `[data-player-clock]` text (comment and reaction forms send the timestamp natively);
- seeks on clicks of `[data-seek-ms]` (comments, markers, transcript lines) and on the marker strip;
- builds the transcript list (`[data-transcript]`) from the WebVTT `<track>` and highlights the current line;
- registers every listener with `cleanup`.

Read it before writing a new component; keep the same style.

## Decide whether a component helps

Good fits: the player, a future timeline/annotation layer on the watch page, a waveform, an upload progress meter driven by live patches. Poor fits: forms, disclosures, lists, pagination, anything the server can render. Explain the concrete lifecycle or duplication a component removes before adding one.

## Contract first

Write down before implementing:

- Tag (`easyshot-` prefix) and host id; DOM mode (`light` when it should share `app.css`).
- Inputs: server-rendered attributes/props (non-sensitive), and which live patches may change them.
- Outputs: DOM `CustomEvent` names and `detail` shapes, or named native inputs the component fills (preferred, so form encoding and the no-JS path keep working).
- Who owns which DOM: the server owns the host and everything outside the component's private subtree.
- The no-JavaScript fallback.

The server stays authoritative for everything persisted (titles, comments, visibility). A component may propose an edit; the surrounding native form submits it.

## Morphs and live patches

The watch page is patched live over SSE. Keep the host's id and structure stable so morphs update its inputs without recreating it (a recreated `<video>` would restart playback). Patch regions around the component rather than through it; use `data-ignore-morph` only for a genuinely client-owned subtree and never to block server-owned content or access changes. Test: initial mount, prop changes from a live patch, repeated patches, removal and reinsertion, two instances on one page.

## Verify

`mise run server:test` cannot prove a component works. Use a real browser (Playwright was used before): console free of missing exports, duplicate registrations, expression or CSP errors; keyboard access and labels; focus retained across patches; native form values correct with and without Datastar; cleanup on removal. State what you verified.

Lifecycle, props, events and form details: [component integration](references/integration.md). API reference: [Rocket](https://data-star.dev/reference/rocket); check the bundle's actual exports before using newer APIs.
