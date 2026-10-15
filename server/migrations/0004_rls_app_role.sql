-- Application role and row-level security for screenshots.
--
-- RLS only binds roles that are neither superusers nor BYPASSRLS, so the server must not
-- connect as the migration (owner) role. This creates shotglass_app when missing (local
-- development and tests; the dev password is 'shotglass_app') and grants it data access.
-- In production create the role beforehand with its own password; this migration then only
-- grants. Migrations keep running as the table owner.
--
-- Tables WITHOUT a policy, on purpose: users, sessions, auth_codes, api_tokens and
-- login_attempts. They are read before a principal is known (sign-in, bearer-token and
-- session lookup, code checks) and every query filters by an explicit user id, email or
-- token hash. Every owner-scoped table (screenshots, videos, item_*) has a FORCE'd policy.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'shotglass_app') THEN
        CREATE ROLE shotglass_app LOGIN NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE NOINHERIT
            PASSWORD 'shotglass_app';
    END IF;
END
$$;

-- Grants target the schema the migrations run in (public, or a per-test schema).
DO $$
DECLARE
    s text := current_schema();
BEGIN
    EXECUTE format('GRANT USAGE ON SCHEMA %I TO shotglass_app', s);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA %I TO shotglass_app', s);
    EXECUTE format('GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA %I TO shotglass_app', s);
    EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO shotglass_app', s);
    EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT USAGE, SELECT ON SEQUENCES TO shotglass_app', s);
    -- The migration ledger belongs to the owner alone.
    EXECUTE format('REVOKE ALL ON TABLE %I._migrations FROM shotglass_app', s);
END
$$;

ALTER TABLE screenshots ENABLE ROW LEVEL SECURITY;
ALTER TABLE screenshots FORCE ROW LEVEL SECURITY;
CREATE POLICY screenshots_owner ON screenshots FOR ALL
    USING (user_id = current_setting('app.user_id', true))
    WITH CHECK (user_id = current_setting('app.user_id', true));
-- Public `/s/{slug}` resolution: only the one slug named by the transaction.
CREATE POLICY screenshots_share_read ON screenshots FOR SELECT
    USING (slug = current_setting('app.share_slug', true));
CREATE POLICY screenshots_maintenance ON screenshots FOR ALL
    USING (current_setting('app.rls_bypass', true) = 'maintenance')
    WITH CHECK (current_setting('app.rls_bypass', true) = 'maintenance');
