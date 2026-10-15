-- Upload progress for recordings that are still being recorded, and live updates for every
-- signed-in screen.
--
-- videos.uploaded_bytes / recording_ended_at: the Mac app reports progress about once a
-- second while it streams parts (POST /v1/videos/{id}/progress), so viewers and the library
-- see "Recording live… N MB uploaded" and then "Finishing…" before the player appears.
--
-- owner_id on the conversation tables: the owner of the item (copied from videos.user_id
-- by the server on insert). It lets the NOTIFY payload reach the owner's library without a
-- lookup that row-level security would hide from anonymous viewers.
--
-- The live trigger now also covers sessions (sign-in/out, revocation), API tokens and the
-- users row (verification, password changes). Payloads still carry ids only. A session's
-- notifications name its row id, never its token or token hash.

ALTER TABLE videos ADD COLUMN IF NOT EXISTS uploaded_bytes BIGINT NOT NULL DEFAULT 0;
ALTER TABLE videos ADD COLUMN IF NOT EXISTS recording_ended_at BIGINT NULL;
ALTER TABLE item_comments ADD COLUMN IF NOT EXISTS owner_id TEXT NULL;
ALTER TABLE item_reactions ADD COLUMN IF NOT EXISTS owner_id TEXT NULL;
ALTER TABLE item_views ADD COLUMN IF NOT EXISTS owner_id TEXT NULL;

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
    ELSIF TG_TABLE_NAME = 'sessions' THEN
        payload := json_build_object('t', 'session', 'item', r.id, 'owner', r.user_id,
            'ws', NULL, 'op', lower(TG_OP));
    ELSIF TG_TABLE_NAME = 'api_tokens' THEN
        payload := json_build_object('t', 'token', 'item', r.id, 'owner', r.user_id,
            'ws', NULL, 'op', lower(TG_OP));
    ELSIF TG_TABLE_NAME = 'users' THEN
        payload := json_build_object('t', 'user', 'item', r.id, 'owner', r.id,
            'ws', NULL, 'op', lower(TG_OP));
    ELSE
        payload := json_build_object(
            't', CASE TG_TABLE_NAME
                     WHEN 'item_comments' THEN 'comments'
                     WHEN 'item_reactions' THEN 'reactions'
                     ELSE 'views' END,
            'item', r.item_id, 'owner', r.owner_id, 'ws', r.workspace_id, 'op', lower(TG_OP));
    END IF;
    PERFORM pg_notify('easyshot_live', payload::text);
    RETURN NULL;
END
$$;

-- last_used_at changes on every API request; only sign-in, device rename and removal matter.
DROP TRIGGER IF EXISTS sessions_live ON sessions;
CREATE TRIGGER sessions_live AFTER INSERT OR DELETE OR UPDATE OF device_name ON sessions
    FOR EACH ROW EXECUTE FUNCTION easyshot_notify_live();

DROP TRIGGER IF EXISTS api_tokens_live ON api_tokens;
CREATE TRIGGER api_tokens_live AFTER INSERT OR DELETE OR UPDATE OF revoked_at, name ON api_tokens
    FOR EACH ROW EXECUTE FUNCTION easyshot_notify_live();

DROP TRIGGER IF EXISTS users_live ON users;
CREATE TRIGGER users_live AFTER UPDATE OF email, email_verified_at, password_hash ON users
    FOR EACH ROW EXECUTE FUNCTION easyshot_notify_live();
