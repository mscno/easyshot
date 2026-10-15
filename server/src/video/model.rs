//! Toasty models for shared items. Tables come from `migrations/0003_videos.sql`; see
//! `crate::orm` for why fields are limited to `String`/`i64`.
//!
//! Only videos exist today (`Video::kind == "video"`), but the conversation models hang off
//! a generic `item_id` and every row carries a nullable `workspace_id`, so screenshots and
//! team workspaces can join later without reshaping these tables.

#[derive(Debug, Clone, toasty::Model)]
#[table = "videos"]
pub struct Video {
    #[key]
    pub id: String,
    /// `video` for now; reserved for a unified items table (`screenshot`, ...).
    pub kind: String,
    #[index]
    pub user_id: String,
    /// Reserved for team workspaces; always `None` today.
    pub workspace_id: Option<String>,
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
    /// See [`crate::video::scope::Visibility`].
    pub visibility: String,
    pub password_hash: Option<String>,
    pub created_at: i64,
    pub updated_at: i64,
    pub ready_at: Option<i64>,
    pub expires_at: i64,
    /// Bytes the app reports as uploaded while still recording (`POST …/progress`).
    pub uploaded_bytes: i64,
    /// When the app reported that recording stopped; `None` while still recording.
    pub recording_ended_at: Option<i64>,
}

#[derive(Debug, Clone, toasty::Model)]
#[table = "item_comments"]
pub struct Comment {
    #[key]
    pub id: String,
    #[index]
    pub item_id: String,
    pub workspace_id: Option<String>,
    /// The item owner, so changes reach their library (see `migrations/0006_…`).
    pub owner_id: Option<String>,
    /// Set for signed-in members; `None` for guests.
    pub user_id: Option<String>,
    pub author_name: String,
    pub body: String,
    pub timestamp_ms: Option<i64>,
    pub created_at: i64,
}

#[derive(Debug, Clone, toasty::Model)]
#[table = "item_reactions"]
pub struct Reaction {
    #[key]
    pub id: String,
    #[index]
    pub item_id: String,
    pub workspace_id: Option<String>,
    pub owner_id: Option<String>,
    pub user_id: Option<String>,
    pub emoji: String,
    pub timestamp_ms: Option<i64>,
    pub created_at: i64,
}

#[derive(Debug, Clone, toasty::Model)]
#[table = "item_views"]
pub struct ItemView {
    #[key]
    pub id: String,
    #[index]
    pub item_id: String,
    pub workspace_id: Option<String>,
    pub viewer_hash: String,
    pub first_seen: i64,
    pub owner_id: Option<String>,
}

pub fn models() -> toasty::ModelSet {
    toasty::models!(Video, Comment, Reaction, ItemView)
}
