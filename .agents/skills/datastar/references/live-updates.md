# Live updates: every open screen stays current

Product requirement: whatever a page shows (status, titles, comments, reactions, view counts, library rows, upload progress, visibility) updates on every open page showing it, in other tabs, devices and server instances, without reload.

## Current and decided architecture

- **Per-page stream.** Each live page opens one Datastar SSE stream on load, e.g. the watch page's `data-init` runs `@get('/v/{slug}/live?since=…', {retry: 'always', retryMaxCount: …})`. The handler (`watch::live`) subscribes, then re-renders dirty regions and patches them by stable id.
- **Change signals, not data.** Writers commit, then a small change (`video::live::Change`: comments, reactions, video, gone) is published for the item. Payloads carry ids and kinds only, never user content; the stream re-reads through the viewer's scope.
- **Fan-out across instances (decided direction).** Postgres `LISTEN/NOTIFY` on channel `easyshot_live`, fed by triggers on the owned tables, with one dedicated listener connection per process (the only non-Toasty connection besides migrations). The listener reconnects with backoff and broadcasts a resync on reconnect. This replaces the earlier in-process hub plus 20 s timer resync. Check `server/src/video/live.rs` for what has landed.
- **Snapshots, not replay.** Reconnects, lagging receivers and listener reconnects all trigger a full re-render of the page's regions from the DB.

## Adding live behavior to a page

1. Give each region a stable id and a component that renders it from the DB through the viewer's `Scope`.
2. Make every write that affects it publish a change for the affected item/owner (or rely on the table's NOTIFY trigger once it exists; then do not double-publish).
3. In the page's stream, map the change to dirty regions; re-render only those.
4. Re-check access during re-render: if the viewer lost access, patch the page into its unavailable state and end the stream.
5. Test it: an HTTP test that a write produces the patch on an open stream (and, for NOTIFY, on a second router with its own pool), plus a two-tab browser check.

## Limits

- One stream per page; streams are cheap but each holds an HTTP connection. Avoid per-row streams.
- Bound queues; coalesce bursts (many reactions) into one re-render.
- Keep-alive 15 s for proxies. Never hold a DB connection between events.
- Owner-only pages (library) subscribe by owner/workspace, not by item, and must not leak other owners' events: NOTIFY payloads are ids, and the re-render runs under RLS.
