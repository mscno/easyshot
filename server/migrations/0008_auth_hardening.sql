-- A verification code mailed for a sign-up attempt (or for a password sign-in on an
-- unverified account) carries that attempt's argon2 password hash and is bound to the
-- attempt: only the sha256 of a random nonce handed to whoever made the attempt is
-- stored, and the code is accepted only together with that nonce. When such a code first
-- proves the mailbox of a never-verified account, the account is claimed in one
-- transaction: every session and API token is revoked and the carried password replaces
-- whatever was set before (a code without one leaves an unusable password). Codes carry
-- both columns or neither; the password is cleared once the code is used.
ALTER TABLE auth_codes ADD COLUMN IF NOT EXISTS password_hash TEXT NULL;
ALTER TABLE auth_codes ADD COLUMN IF NOT EXISTS attempt_hash TEXT NULL;
