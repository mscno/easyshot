# Live updates: every open screen stays current

Product requirement: whatever a page shows (status, upload progress, titles, comments, reactions, view counts, library rows, devices, tokens, visibility) updates on every open page showing it, in other tabs, devices and server instances, without reload.

## Architecture (in place)

- **One stream per live page.** The page's root element runs `data-init="@get('/…/live?since=<render time>', {retry: 'always', retryMaxCount: 1000})"`: the watch page (`/v/{slug}/live`, `web/watch.rs`), the library (`/library/live`, `web/account.rs`) and the account page (`/account/live`, `web/settings.rs`). `since` lets the handler skip the first render when the page is fresh.
- **Triggers, not publish calls.** Postgres triggers (`server/migrations/0005_live_notify.sql`, `0006_upload_progress_and_live.sql`) `NOTIFY easyshot_live` on every committed change to `videos`, `item_comments`/`item_reactions`/`item_views` (with the item's `owner_id`), `screenshots`, `sessions` (insert, delete, device rename; not `last_used_at`), `api_tokens` and `users` (email, verification, password). Payloads are `{t, item, owner, ws, op}`: ids and kinds only, never content or tokens. Handlers never publish by hand; a new table that pages show needs a trigger branch.
- **Hub and topics** (`server/src/video/live.rs`). One `LISTEN` connection per process fans pings (`Ping { change, item }`) out to topics: the item id (watch page), `user:{id}` (library, account), `session:{session row id}` (every stream opened with that session). Streams subscribe to their topic plus their session topic and wait with `next_ping`/`try_ping`, coalescing a burst into one render.
- **Snapshots, not replay.** A listener (re)connect sends `Resync` to every topic; a lagging receiver is treated as a resync; client reconnects re-render when `since` is stale. All three re-render from the DB.
- **Re-authorize every render.** Each render re-reads the viewer (`web::member`). If the stream's session is gone, queue `web::signed_out_patch(next)` (an `#live-redirect` element with `data-init` that navigates to `/login?next=…`) and end. If access changed, patch the page into its locked/unavailable state and end.
- **Bounded.** `web::admit_stream` allows 12 open streams per session (24 per address for anonymous viewers); the slot frees when the stream drops. 15 s keep-alive; streams end after 6 hours (the client reconnects).

## Adding live behavior to a page

1. Give each region a stable id and render it from a component that reads the DB through the viewer's `Scope` (or the session's user for account data).
2. Make sure the table that changes has a trigger branch and the payload reaches a topic the page subscribes to (owner id on child rows, for instance).
3. In the stream, map `Change` kinds to dirty regions; on list pages patch only the changed row, and split a row into separately patched parts when it holds user input (the library patches `#meta-{id}` for progress and counts and the full `#item-{id}` card only when its title, visibility or readiness changed, so an open `<details>` and typing survive morphs).
4. Values shown once (a new API token) live outside any region the stream re-renders.
5. Test it in `server/tests/web.rs`: open the stream with `open_stream`, make the change through the API or another session, `read_until` the patch. For cross-instance behavior use a second router with its own pool (`live_updates_cross_server_instances`). Then a two-context browser check.

## Limits

- One stream per page; avoid per-row streams.
- NOTIFY is database-wide: parallel tests in one database see each other's pings, harmless because topics are random ids.
- `LISTEN` needs a direct or session-mode connection (`DATABASE_URL`), never transaction pooling.
- Every unique view re-renders the watch-page header for open viewers; throttle if that becomes hot.
