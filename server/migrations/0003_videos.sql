-- Loom-style videos and their conversation. The tables are mapped by the Toasty models in
-- src/video/model.rs; this migration is their only schema owner (Toasty never creates or
-- alters tables). Same conventions as 0001: UUID text ids, epoch-ms BIGINTs, no foreign
-- keys (the app deletes child rows).
--
-- Team-ready without teams: every table has a nullable workspace_id (unused for now), the
-- conversation tables reference a generic item_id and `videos` carries a `kind`, so videos
-- can later merge with screenshots into one items table. `visibility` and `kind` have no
-- CHECK constraint on purpose: the application enum grows (e.g. 'workspace') without a
-- constraint migration.
--
-- Row-level security is FORCE'd on every table here (it binds the owner too; the app role
-- is NOBYPASSRLS, see 0004). Policies read the transaction-local settings the server sets
-- with set_config(..., true) at the start of each transaction:
--   app.user_id        owner access to own items and their conversation
--   app.workspace_id   reserved: workspace access (NULL workspace_id never matches)
--   app.share_slug     read one item by its share slug (the public share-link path)
--   app.share_item_id  that item's conversation: read, and insert comments/reactions/views
--   app.rls_bypass     'maintenance' only, for retention and account purge jobs

CREATE TABLE IF NOT EXISTS videos (
    id TEXT PRIMARY KEY,
    kind TEXT NOT NULL DEFAULT 'video',
    user_id TEXT NOT NULL,
    workspace_id TEXT NULL,
    slug TEXT NOT NULL UNIQUE,
    title TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'ready')),
    object_key TEXT NOT NULL,
    upload_id TEXT NULL,
    content_type TEXT NOT NULL,
    byte_size BIGINT NOT NULL DEFAULT 0,
    duration_ms BIGINT NOT NULL DEFAULT 0,
    width BIGINT NULL,
    height BIGINT NULL,
    thumbnail_key TEXT NULL,
    transcript_key TEXT NULL,
    visibility TEXT NOT NULL DEFAULT 'link',
    password_hash TEXT NULL,
    created_at BIGINT NOT NULL,
    updated_at BIGINT NOT NULL,
    ready_at BIGINT NULL,
    expires_at BIGINT NOT NULL
);
CREATE INDEX IF NOT EXISTS videos_user_list_idx ON videos (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS videos_workspace_idx ON videos (workspace_id, created_at DESC) WHERE workspace_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS videos_expires_idx ON videos (expires_at);
CREATE INDEX IF NOT EXISTS videos_pending_idx ON videos (created_at) WHERE status = 'pending';

CREATE TABLE IF NOT EXISTS item_comments (
    id TEXT PRIMARY KEY,
    item_id TEXT NOT NULL,
    workspace_id TEXT NULL,
    user_id TEXT NULL,
    author_name TEXT NOT NULL,
    body TEXT NOT NULL,
    timestamp_ms BIGINT NULL,
    created_at BIGINT NOT NULL
);
CREATE INDEX IF NOT EXISTS item_comments_item_idx ON item_comments (item_id, created_at);

CREATE TABLE IF NOT EXISTS item_reactions (
    id TEXT PRIMARY KEY,
    item_id TEXT NOT NULL,
    workspace_id TEXT NULL,
    user_id TEXT NULL,
    emoji TEXT NOT NULL,
    timestamp_ms BIGINT NULL,
    created_at BIGINT NOT NULL
);
CREATE INDEX IF NOT EXISTS item_reactions_item_idx ON item_reactions (item_id, created_at);

-- One row per viewer per UTC day; `viewer_hash` is a keyed hash of day + client address +
-- user agent, so raw addresses are never stored. View counts are counted from here.
CREATE TABLE IF NOT EXISTS item_views (
    id TEXT PRIMARY KEY,
    item_id TEXT NOT NULL,
    workspace_id TEXT NULL,
    viewer_hash TEXT NOT NULL,
    first_seen BIGINT NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS item_views_unique_idx ON item_views (item_id, viewer_hash);

-- ---------- row-level security ----------

ALTER TABLE videos ENABLE ROW LEVEL SECURITY;
ALTER TABLE videos FORCE ROW LEVEL SECURITY;
CREATE POLICY videos_owner ON videos FOR ALL
    USING (
        user_id = current_setting('app.user_id', true)
        OR (workspace_id IS NOT NULL AND workspace_id = current_setting('app.workspace_id', true))
    )
    WITH CHECK (
        user_id = current_setting('app.user_id', true)
        OR (workspace_id IS NOT NULL AND workspace_id = current_setting('app.workspace_id', true))
    );
CREATE POLICY videos_share_read ON videos FOR SELECT
    USING (slug = current_setting('app.share_slug', true));
CREATE POLICY videos_maintenance ON videos FOR ALL
    USING (current_setting('app.rls_bypass', true) = 'maintenance')
    WITH CHECK (current_setting('app.rls_bypass', true) = 'maintenance');

-- Conversation rows follow their item: the owner may do anything; a share-link viewer may
-- read and add rows for the one item resolved from the share slug, never update or delete.
DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['item_comments', 'item_reactions', 'item_views'] LOOP
        EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
        EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', t);
        EXECUTE format($p$
            CREATE POLICY %1$s_owner ON %1$I FOR ALL
                USING (EXISTS (SELECT 1 FROM videos v WHERE v.id = %1$I.item_id AND (
                    v.user_id = current_setting('app.user_id', true)
                    OR (v.workspace_id IS NOT NULL AND v.workspace_id = current_setting('app.workspace_id', true)))))
                WITH CHECK (EXISTS (SELECT 1 FROM videos v WHERE v.id = %1$I.item_id AND (
                    v.user_id = current_setting('app.user_id', true)
                    OR (v.workspace_id IS NOT NULL AND v.workspace_id = current_setting('app.workspace_id', true)))))
        $p$, t);
        EXECUTE format($p$
            CREATE POLICY %1$s_share_read ON %1$I FOR SELECT
                USING (item_id = current_setting('app.share_item_id', true)
                    AND EXISTS (SELECT 1 FROM videos v WHERE v.id = %1$I.item_id
                        AND v.slug = current_setting('app.share_slug', true)))
        $p$, t);
        EXECUTE format($p$
            CREATE POLICY %1$s_share_insert ON %1$I FOR INSERT
                WITH CHECK (item_id = current_setting('app.share_item_id', true)
                    AND EXISTS (SELECT 1 FROM videos v WHERE v.id = %1$I.item_id
                        AND v.slug = current_setting('app.share_slug', true)))
        $p$, t);
        EXECUTE format($p$
            CREATE POLICY %1$s_maintenance ON %1$I FOR ALL
                USING (current_setting('app.rls_bypass', true) = 'maintenance')
                WITH CHECK (current_setting('app.rls_bypass', true) = 'maintenance')
        $p$, t);
    END LOOP;
END
$$;
