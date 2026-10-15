-- A verification code mailed for a sign-up attempt (or for a password sign-in on an
-- unverified account) carries that attempt's argon2 password hash. When the code first
-- proves the mailbox of a never-verified account, the account is claimed in one
-- transaction: every session and API token is revoked and this password replaces whatever
-- was set before (a code without one leaves an unusable password). Cleared once used.
ALTER TABLE auth_codes ADD COLUMN IF NOT EXISTS password_hash TEXT NULL;
