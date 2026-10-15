-- Byte reservations for recordings that are still uploading.
--
-- Multipart parts go straight from the app to object storage, so the server bounds them
-- before it signs anything: every presigned UploadPart URL carries the part's exact
-- Content-Length, and that size is reserved here first. Per video the reserved parts may
-- not exceed MAX_VIDEO_BYTES, per account the parts of all unfinished uploads may not
-- exceed MAX_PENDING_UPLOAD_BYTES. Completion checks the assembled object against the
-- reserved sizes of the parts it names, then deletes the rows; purging a video deletes them
-- too. A part's size is fixed once reserved, so stored bytes never exceed the reservation.
--
-- A child table rather than columns on `videos`: completion needs each part's size (up to
-- 10,000 per video), and writing reservations here does not fire the videos live trigger
-- for every batch of part URLs. No live trigger: no page shows reservations.
--
-- Writers serialize per account with pg_advisory_xact_lock (src/video/service.rs), so the
-- pending-upload cap and the budgets hold under concurrent requests.

CREATE TABLE IF NOT EXISTS upload_parts (
    video_id TEXT NOT NULL,
    part_number BIGINT NOT NULL CHECK (part_number BETWEEN 1 AND 10000),
    user_id TEXT NOT NULL,
    workspace_id TEXT NULL,
    byte_size BIGINT NOT NULL CHECK (byte_size > 0),
    created_at BIGINT NOT NULL,
    PRIMARY KEY (video_id, part_number)
);
CREATE INDEX IF NOT EXISTS upload_parts_user_idx ON upload_parts (user_id);

ALTER TABLE upload_parts ENABLE ROW LEVEL SECURITY;
ALTER TABLE upload_parts FORCE ROW LEVEL SECURITY;
-- The owner reads and writes reservations of their own videos only; a row cannot name
-- another owner's video.
CREATE POLICY upload_parts_owner ON upload_parts FOR ALL
    USING (user_id = current_setting('app.user_id', true))
    WITH CHECK (
        user_id = current_setting('app.user_id', true)
        AND EXISTS (SELECT 1 FROM videos v WHERE v.id = upload_parts.video_id
            AND v.user_id = upload_parts.user_id)
    );
CREATE POLICY upload_parts_maintenance ON upload_parts FOR ALL
    USING (current_setting('app.rls_bypass', true) = 'maintenance')
    WITH CHECK (current_setting('app.rls_bypass', true) = 'maintenance');

DO $$
BEGIN
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE %I.upload_parts TO easyshot_app',
        current_schema());
END
$$;
