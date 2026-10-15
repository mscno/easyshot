//! Development seed: two confirmed accounts (safe to rerun). Uploads need object storage, so
//! no videos are seeded; record one with the app or the curl flow in the README.

use crate::auth::hash_password_blocking;
use crate::db::{Db, DbError};
use crate::repo::{self, now_ms};

pub const ACCOUNTS: [&str; 2] = ["dev@easyshot.test", "teammate@easyshot.test"];
pub const PASSWORD: &str = "easyshot-dev-password";

pub async fn run(owner_url: &str) -> Result<String, Box<dyn std::error::Error + Send + Sync>> {
    let db = Db::connect_url(owner_url, 2).await?;
    let mut out = Vec::new();
    for email in ACCOUNTS {
        let now = now_ms();
        let id = uuid::Uuid::new_v4();
        let hash = hash_password_blocking(PASSWORD.into()).await?;
        match repo::create_user(&db, id, email, &hash, now).await {
            Ok(()) => out.push(format!("created {email}")),
            Err(DbError::UniqueViolation) => out.push(format!("exists  {email}")),
            Err(e) => return Err(e.into()),
        }
        if let Some(u) = repo::find_user_for_login(&db, email).await? {
            repo::set_email_verified(&db, u.id, now).await?;
        }
    }
    out.push(format!("password: {PASSWORD}"));
    Ok(out.join("\n"))
}
