-- Loom-style videos and their conversation. These tables are mapped by the Toasty models in
-- src/video/model.rs, but this migration is their only schema owner (Toasty never creates
-- or alters tables). Same portable conventions as 0001: UUID text ids, epoch-ms BIGINTs,
-- 0/1 integers, no foreign keys (the app deletes child rows).

CREATE TABLE IF NOT EXISTS videos (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
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
    privacy TEXT NOT NULL DEFAULT 'link' CHECK (privacy IN ('link', 'password', 'private')),
    password_hash TEXT NULL,
    view_count BIGINT NOT NULL DEFAULT 0,
    created_at BIGINT NOT NULL,
    updated_at BIGINT NOT NULL,
    ready_at BIGINT NULL,
    expires_at BIGINT NOT NULL
);
CREATE INDEX IF NOT EXISTS videos_user_list_idx ON videos (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS videos_expires_idx ON videos (expires_at);
CREATE INDEX IF NOT EXISTS videos_pending_idx ON videos (created_at) WHERE status = 'pending';

CREATE TABLE IF NOT EXISTS video_comments (
    id TEXT PRIMARY KEY,
    video_id TEXT NOT NULL,
    user_id TEXT NULL,
    author_name TEXT NOT NULL,
    body TEXT NOT NULL,
    timestamp_ms BIGINT NULL,
    created_at BIGINT NOT NULL
);
CREATE INDEX IF NOT EXISTS video_comments_video_idx ON video_comments (video_id, created_at);

CREATE TABLE IF NOT EXISTS video_reactions (
    id TEXT PRIMARY KEY,
    video_id TEXT NOT NULL,
    user_id TEXT NULL,
    emoji TEXT NOT NULL,
    timestamp_ms BIGINT NULL,
    created_at BIGINT NOT NULL
);
CREATE INDEX IF NOT EXISTS video_reactions_video_idx ON video_reactions (video_id, created_at);

-- One row per viewer per UTC day; `viewer_hash` is a keyed hash of day + client address +
-- user agent, so raw addresses are never stored.
CREATE TABLE IF NOT EXISTS video_views (
    id TEXT PRIMARY KEY,
    video_id TEXT NOT NULL,
    viewer_hash TEXT NOT NULL,
    first_seen BIGINT NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS video_views_unique_idx ON video_views (video_id, viewer_hash)
