//! Who may see or manage an item. Every read and write of the video domain goes through a
//! [`Scope`] instead of ad-hoc `user_id` comparisons, so workspaces can be added in one
//! place: a member's scope will gain workspace ids, `can_manage`/`access` will consult them,
//! and `items` will include workspace items.
//!
//! The scope also produces the database's row-level-security [`Context`]: the application
//! checks below decide what to show, and the policies in `migrations/0003_videos.sql` deny
//! anything outside the scope even if a query forgets its filter.

use uuid::Uuid;

use super::model::Video;
use crate::db::Context;
use crate::orm::{begin, orm_err};
use crate::error::{AppError, AppResult};
use crate::repo::now_ms;
use crate::state::AppState;

/// Who can open an item's link. Stored as text without a CHECK constraint so it can grow
/// (e.g. `Workspace`) without a table rebuild.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Visibility {
    /// Anyone with the link.
    Link,
    /// Anyone with the link who knows the password.
    Password,
    /// Only the owner.
    Private,
}

impl Visibility {
    pub const ALL: [Visibility; 3] = [Visibility::Link, Visibility::Password, Visibility::Private];

    pub fn parse(s: &str) -> Option<Visibility> {
        match s {
            "link" => Some(Visibility::Link),
            "password" => Some(Visibility::Password),
            "private" => Some(Visibility::Private),
            _ => None,
        }
    }
    pub fn as_str(self) -> &'static str {
        match self {
            Visibility::Link => "link",
            Visibility::Password => "password",
            Visibility::Private => "private",
        }
    }
    pub fn label(self) -> &'static str {
        match self {
            Visibility::Link => "Anyone with the link",
            Visibility::Password => "Password protected",
            Visibility::Private => "Only me",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Access {
    Allowed,
    NeedsPassword,
    Denied,
}

/// The requesting principal. Anonymous viewers have no user id.
#[derive(Debug, Clone, Default)]
pub struct Scope {
    pub user_id: Option<Uuid>,
}

impl Scope {
    pub fn anonymous() -> Scope {
        Scope { user_id: None }
    }
    pub fn user(id: Uuid) -> Scope {
        Scope { user_id: Some(id) }
    }

    /// RLS context for work done on behalf of this principal.
    pub fn context(&self) -> Context {
        Context {
            user_id: self.user_id.map(|u| u.to_string()),
            ..Context::default()
        }
    }

    /// RLS SHARE PATH: this principal resolving one share link. The database then exposes
    /// only the item with this slug (read-only) besides the principal's own items.
    pub fn share_lookup(&self, slug: &str) -> Context {
        Context {
            share_slug: Some(slug.to_string()),
            ..self.context()
        }
    }

    /// RLS SHARE PATH, after the link resolved to `v`: read and add conversation rows of
    /// that one item.
    pub fn share(&self, v: &Video) -> Context {
        Context {
            share_slug: Some(v.slug.clone()),
            share_item_id: Some(v.id.clone()),
            ..self.context()
        }
    }

    pub fn owns(&self, v: &Video) -> bool {
        self.user_id.is_some_and(|u| u.to_string() == v.user_id)
    }

    /// Rename, change visibility, delete, upload. Owner only for now.
    pub fn can_manage(&self, v: &Video) -> bool {
        self.owns(v)
    }

    /// Whether this principal may watch `v`; `unlocked` is a valid password cookie.
    pub fn access(&self, v: &Video, unlocked: bool) -> Access {
        if v.expires_at <= now_ms() {
            return Access::Denied;
        }
        if self.can_manage(v) {
            return Access::Allowed;
        }
        match Visibility::parse(&v.visibility) {
            Some(Visibility::Link) => Access::Allowed,
            Some(Visibility::Password) if unlocked => Access::Allowed,
            Some(Visibility::Password) => Access::NeedsPassword,
            // Private, or a value this build does not know: fail closed.
            _ => Access::Denied,
        }
    }

    /// An item this principal may manage, or `NotFound` (missing and foreign look alike).
    pub async fn managed(&self, st: &AppState, id: &str) -> AppResult<Video> {
        if self.user_id.is_none() || Uuid::parse_str(id).is_err() {
            return Err(AppError::NotFound);
        }
        let mut db = st.orm().await?;
        let mut tx = begin(&mut db, &self.context()).await?;
        let v = Video::filter_by_id(id)
            .first()
            .exec(&mut tx)
            .await
            .map_err(orm_err)?;
        tx.commit().await.map_err(orm_err)?;
        v.filter(|v| self.can_manage(v) && v.expires_at > now_ms())
            .ok_or(AppError::NotFound)
    }

    /// Items listed in this principal's library, newest first.
    pub async fn items(&self, st: &AppState, limit: usize) -> AppResult<Vec<Video>> {
        let Some(user) = self.user_id else {
            return Ok(Vec::new());
        };
        let mut db = st.orm().await?;
        let mut tx = begin(&mut db, &self.context()).await?;
        let now = now_ms();
        let mut v = Video::filter_by_user_id(user.to_string())
            .exec(&mut tx)
            .await
            .map_err(orm_err)?;
        tx.commit().await.map_err(orm_err)?;
        v.retain(|v| v.expires_at > now && self.can_manage(v));
        v.sort_by(|a, b| b.created_at.cmp(&a.created_at).then(b.id.cmp(&a.id)));
        v.truncate(limit);
        Ok(v)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn video(owner: Uuid, visibility: &str) -> Video {
        Video {
            id: "i".into(),
            kind: "video".into(),
            user_id: owner.to_string(),
            workspace_id: None,
            slug: "s".into(),
            title: "t".into(),
            status: "ready".into(),
            object_key: "k".into(),
            upload_id: None,
            content_type: "video/mp4".into(),
            byte_size: 1,
            duration_ms: 1,
            width: None,
            height: None,
            thumbnail_key: None,
            transcript_key: None,
            visibility: visibility.into(),
            password_hash: None,
            created_at: 0,
            updated_at: 0,
            ready_at: None,
            expires_at: i64::MAX,
        }
    }

    #[test]
    fn access_rules() {
        let owner = Uuid::new_v4();
        let other = Scope::user(Uuid::new_v4());
        let anon = Scope::anonymous();
        let me = Scope::user(owner);
        assert_eq!(anon.access(&video(owner, "link"), false), Access::Allowed);
        assert_eq!(anon.access(&video(owner, "password"), false), Access::NeedsPassword);
        assert_eq!(other.access(&video(owner, "password"), true), Access::Allowed);
        assert_eq!(other.access(&video(owner, "private"), true), Access::Denied);
        assert_eq!(anon.access(&video(owner, "workspace"), true), Access::Denied);
        assert_eq!(me.access(&video(owner, "private"), false), Access::Allowed);
        assert!(me.can_manage(&video(owner, "link")) && !other.can_manage(&video(owner, "link")));
        let mut expired = video(owner, "link");
        expired.expires_at = 1;
        assert_eq!(me.access(&expired, false), Access::Denied);
    }
}
