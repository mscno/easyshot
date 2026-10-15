-- Portable schema: runs unchanged on Postgres and SQLite/libSQL (Turso).
-- Conventions: ids are UUID strings made by the app; timestamps are unix epoch
-- milliseconds set by the app; token hashes are lowercase sha256 hex; booleans are 0/1.
-- No foreign keys / ON DELETE CASCADE: the app deletes child rows explicitly.
-- Statements are split on ';' by the migration runner, so keep ';' out of literals.

CREATE TABLE IF NOT EXISTS users (
    id TEXT PRIMARY KEY,
    email TEXT NOT NULL UNIQUE,
    password_hash TEXT NOT NULL,
    plan TEXT NOT NULL DEFAULT 'free',
    email_verified_at BIGINT NULL,
    created_at BIGINT NOT NULL,
    updated_at BIGINT NOT NULL,
    disabled_at BIGINT NULL,
    last_seen_at BIGINT NOT NULL
);
CREATE INDEX IF NOT EXISTS users_last_seen_idx ON users (last_seen_at);

CREATE TABLE IF NOT EXISTS sessions (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    token_hash TEXT NOT NULL UNIQUE,
    device_name TEXT NULL,
    created_at BIGINT NOT NULL,
    last_used_at BIGINT NOT NULL,
    expires_at BIGINT NOT NULL
);
CREATE INDEX IF NOT EXISTS sessions_user_idx ON sessions (user_id);
CREATE INDEX IF NOT EXISTS sessions_expires_idx ON sessions (expires_at);

CREATE TABLE IF NOT EXISTS api_tokens (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    name TEXT NOT NULL,
    token_hash TEXT NOT NULL UNIQUE,
    created_at BIGINT NOT NULL,
    last_used_at BIGINT NULL,
    revoked_at BIGINT NULL
);
CREATE INDEX IF NOT EXISTS api_tokens_user_idx ON api_tokens (user_id);

CREATE TABLE IF NOT EXISTS screenshots (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    slug TEXT NOT NULL UNIQUE,
    object_key TEXT NOT NULL,
    content_type TEXT NOT NULL,
    byte_size BIGINT NOT NULL,
    width INTEGER NULL,
    height INTEGER NULL,
    filename TEXT NULL,
    status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'ready')),
    created_at BIGINT NOT NULL,
    uploaded_at BIGINT NULL,
    expires_at BIGINT NOT NULL
);
CREATE INDEX IF NOT EXISTS screenshots_user_list_idx ON screenshots (user_id, created_at DESC, id DESC) WHERE status = 'ready';
CREATE INDEX IF NOT EXISTS screenshots_user_idx ON screenshots (user_id);
CREATE INDEX IF NOT EXISTS screenshots_expires_idx ON screenshots (expires_at);
CREATE INDEX IF NOT EXISTS screenshots_pending_idx ON screenshots (created_at) WHERE status = 'pending';

CREATE TABLE IF NOT EXISTS login_attempts (
    id TEXT PRIMARY KEY,
    email TEXT NOT NULL,
    ip TEXT NULL,
    succeeded INTEGER NOT NULL,
    created_at BIGINT NOT NULL
);
CREATE INDEX IF NOT EXISTS login_attempts_email_idx ON login_attempts (email, created_at);
