//! Toasty models for the video domain. Tables come from `migrations/0003_videos.sql`; see
//! `crate::orm` for why fields are limited to `String`/`i64`.

#![allow(clippy::too_many_arguments)]

#[derive(Debug, Clone, toasty::Model)]
#[table = "videos"]
pub struct Video {
    #[key]
    pub id: String,
    #[index]
    pub user_id: String,
    #[unique]
    pub slug: String,
    pub title: String,
    /// `pending` until the multipart upload completes, then `ready`.
    pub status: String,
    pub object_key: String,
    pub upload_id: Option<String>,
    pub content_type: String,
    pub byte_size: i64,
    pub duration_ms: i64,
    pub width: Option<i64>,
    pub height: Option<i64>,
    pub thumbnail_key: Option<String>,
    pub transcript_key: Option<String>,
    /// `link`, `password` or `private`.
    pub privacy: String,
    pub password_hash: Option<String>,
    pub view_count: i64,
    pub created_at: i64,
    pub updated_at: i64,
    pub ready_at: Option<i64>,
    pub expires_at: i64,
}

#[derive(Debug, Clone, toasty::Model)]
#[table = "video_comments"]
pub struct Comment {
    #[key]
    pub id: String,
    #[index]
    pub video_id: String,
    /// Set for signed-in members; `None` for guests.
    pub user_id: Option<String>,
    pub author_name: String,
    pub body: String,
    pub timestamp_ms: Option<i64>,
    pub created_at: i64,
}

#[derive(Debug, Clone, toasty::Model)]
#[table = "video_reactions"]
pub struct Reaction {
    #[key]
    pub id: String,
    #[index]
    pub video_id: String,
    pub user_id: Option<String>,
    pub emoji: String,
    pub timestamp_ms: Option<i64>,
    pub created_at: i64,
}

#[derive(Debug, Clone, toasty::Model)]
#[table = "video_views"]
pub struct VideoView {
    #[key]
    pub id: String,
    #[index]
    pub video_id: String,
    pub viewer_hash: String,
    pub first_seen: i64,
}

pub fn models() -> toasty::ModelSet {
    toasty::models!(Video, Comment, Reaction, VideoView)
}
