-- Provider-managed logins.
--
-- In production every login is created by the database provider (PlanetScale:
-- `pscale role create`), never by SQL. easyshot_app stays the privilege role that holds the
-- table grants from 0004; the server's login gets those privileges through membership. The
-- login must not be a superuser or BYPASSRLS, so the FORCE'd policies still bind it.
--
-- The migration runner passes the login as the session setting easyshot.app_login
-- (APP_DATABASE_LOGIN, or the user of DATABASE_URL). PlanetScale puts the branch after a dot
-- on the wire (pscale_api_x.branch); the role itself has no suffix, so the function also
-- tries the part before the first dot. Rotating the login: create a new one in PlanetScale,
-- then `mise run db:bootstrap`, which calls the function again.
CREATE OR REPLACE FUNCTION easyshot_grant_app_login(login text, retire_app_login boolean DEFAULT false) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE
    r pg_roles%ROWTYPE;
BEGIN
    SELECT * INTO r FROM pg_roles WHERE rolname = login;
    IF NOT FOUND THEN
        SELECT * INTO r FROM pg_roles WHERE rolname = split_part(login, '.', 1);
    END IF;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'app login % does not exist', login;
    END IF;
    IF r.rolname = 'easyshot_app' THEN
        RETURN r.rolname;
    END IF;
    IF r.rolsuper OR r.rolbypassrls THEN
        RAISE EXCEPTION 'app login % must not be a superuser or BYPASSRLS', r.rolname;
    END IF;
    EXECUTE format('GRANT easyshot_app TO %I WITH INHERIT TRUE', r.rolname);
    -- With a provider login in place, easyshot_app itself no longer signs in. Optional, since
    -- easyshot_app is cluster-wide and local development and tests still log in as it.
    IF retire_app_login THEN
        ALTER ROLE easyshot_app NOLOGIN PASSWORD NULL;
    END IF;
    RETURN r.rolname;
END
$$;
REVOKE ALL ON FUNCTION easyshot_grant_app_login(text, boolean) FROM PUBLIC;

DO $$
DECLARE
    login text := nullif(current_setting('easyshot.app_login', true), '');
BEGIN
    IF login IS NOT NULL THEN
        PERFORM easyshot_grant_app_login(login, true);
    END IF;
END
$$;
