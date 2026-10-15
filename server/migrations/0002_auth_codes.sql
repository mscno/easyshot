-- One-time numeric codes sent by email: verify_email, reset_password, login_otp.
-- Only a salted sha256 of the code is stored. `consumed_at` is also set when a code is
-- superseded by a newer one or burned after too many wrong guesses.

CREATE TABLE IF NOT EXISTS auth_codes (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    purpose TEXT NOT NULL,
    code_hash TEXT NOT NULL,
    attempts INTEGER NOT NULL DEFAULT 0,
    created_at BIGINT NOT NULL,
    expires_at BIGINT NOT NULL,
    consumed_at BIGINT NULL
);
CREATE INDEX IF NOT EXISTS auth_codes_user_idx ON auth_codes (user_id, purpose, created_at);
CREATE INDEX IF NOT EXISTS auth_codes_expires_idx ON auth_codes (expires_at);
