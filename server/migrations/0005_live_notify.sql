-- Live updates across server instances: every committed change to a shared item, its
-- conversation or a screenshot sends a NOTIFY on `easyshot_live`. Payloads carry ids and
-- kinds only, never user content: {"t": kind, "item": id, "owner": user id or null,
-- "ws": workspace id or null, "op": insert|update|delete}. Each server holds one LISTEN
-- connection and re-reads what changed under the viewer's own RLS context
-- (src/video/live.rs). Postgres delivers notifications at commit and drops duplicates
-- within one transaction.

CREATE OR REPLACE FUNCTION easyshot_notify_live() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    r RECORD;
    payload json;
BEGIN
    IF TG_OP = 'DELETE' THEN r := OLD; ELSE r := NEW; END IF;
    IF TG_TABLE_NAME = 'videos' THEN
        payload := json_build_object('t', 'video', 'item', r.id, 'owner', r.user_id,
            'ws', r.workspace_id, 'op', lower(TG_OP));
    ELSIF TG_TABLE_NAME = 'screenshots' THEN
        payload := json_build_object('t', 'screenshot', 'item', r.id, 'owner', r.user_id,
            'ws', NULL, 'op', lower(TG_OP));
    ELSE
        payload := json_build_object(
            't', CASE TG_TABLE_NAME
                     WHEN 'item_comments' THEN 'comments'
                     WHEN 'item_reactions' THEN 'reactions'
                     ELSE 'views' END,
            'item', r.item_id, 'owner', NULL, 'ws', r.workspace_id, 'op', lower(TG_OP));
    END IF;
    PERFORM pg_notify('easyshot_live', payload::text);
    RETURN NULL;
END
$$;

DROP TRIGGER IF EXISTS videos_live ON videos;
CREATE TRIGGER videos_live AFTER INSERT OR UPDATE OR DELETE ON videos
    FOR EACH ROW EXECUTE FUNCTION easyshot_notify_live();

DROP TRIGGER IF EXISTS item_comments_live ON item_comments;
CREATE TRIGGER item_comments_live AFTER INSERT OR UPDATE OR DELETE ON item_comments
    FOR EACH ROW EXECUTE FUNCTION easyshot_notify_live();

DROP TRIGGER IF EXISTS item_reactions_live ON item_reactions;
CREATE TRIGGER item_reactions_live AFTER INSERT OR UPDATE OR DELETE ON item_reactions
    FOR EACH ROW EXECUTE FUNCTION easyshot_notify_live();

DROP TRIGGER IF EXISTS item_views_live ON item_views;
CREATE TRIGGER item_views_live AFTER INSERT OR DELETE ON item_views
    FOR EACH ROW EXECUTE FUNCTION easyshot_notify_live();

DROP TRIGGER IF EXISTS screenshots_live ON screenshots;
CREATE TRIGGER screenshots_live AFTER INSERT OR UPDATE OR DELETE ON screenshots
    FOR EACH ROW EXECUTE FUNCTION easyshot_notify_live();
