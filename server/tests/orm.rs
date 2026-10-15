//! Toasty models over the portable `Db` (libSQL file per test; Postgres when DATABASE_URL is
//! a postgres URL, in its own schema).

use shotglass_server::config::Config;
use shotglass_server::db::Db;
use shotglass_server::orm;
use shotglass_server::video::model::{Comment, Video};

mod common;

#[tokio::test]
async fn toasty_roundtrip_on_all_backends() {
    for t in common::databases().await {
        roundtrip(t.db.clone()).await;
        t.finish().await;
    }
}

fn video(id: &str, slug: &str, user: &str, created: i64) -> Video {
    Video {
        id: id.into(),
        user_id: user.into(),
        slug: slug.into(),
        title: "Demo".into(),
        status: "pending".into(),
        object_key: format!("v/{id}.mp4"),
        upload_id: Some("up".into()),
        content_type: "video/mp4".into(),
        byte_size: 0,
        duration_ms: 0,
        width: None,
        height: None,
        thumbnail_key: None,
        transcript_key: None,
        privacy: "link".into(),
        password_hash: None,
        view_count: 0,
        created_at: created,
        updated_at: created,
        ready_at: None,
        expires_at: created + 1000,
    }
}

async fn roundtrip(db: Db) {
    let _ = Config::for_tests("file::memory:");
    let mut t = orm::connect(&db).await.unwrap();
    let v = video("a1", "slugA", "u1", 10);
    toasty::create!(Video {
        id: v.id.clone(),
        user_id: v.user_id.clone(),
        slug: v.slug.clone(),
        title: v.title.clone(),
        status: v.status.clone(),
        object_key: v.object_key.clone(),
        upload_id: v.upload_id.clone(),
        content_type: v.content_type.clone(),
        byte_size: 0,
        duration_ms: 0,
        width: None::<i64>,
        height: None::<i64>,
        thumbnail_key: None::<String>,
        transcript_key: None::<String>,
        privacy: "link",
        password_hash: None::<String>,
        view_count: 0,
        created_at: 10,
        updated_at: 10,
        ready_at: None::<i64>,
        expires_at: 1010,
    })
    .exec(&mut t)
    .await
    .unwrap();
    let got = Video::get_by_slug(&mut t, "slugA").await.unwrap();
    assert_eq!(got.id, "a1");
    assert_eq!(got.width, None);
    let list = Video::filter_by_user_id("u1").exec(&mut t).await.unwrap();
    assert_eq!(list.len(), 1);
    Video::update_by_id("a1")
        .status("ready")
        .width(Some(1920))
        .exec(&mut t)
        .await
        .unwrap();
    let got = Video::get_by_id(&mut t, "a1").await.unwrap();
    assert_eq!((got.status.as_str(), got.width), ("ready", Some(1920)));
    toasty::create!(Comment {
        id: "c1",
        video_id: "a1",
        user_id: None::<String>,
        author_name: "Guest",
        body: "hi",
        timestamp_ms: Some(1500i64),
        created_at: 11,
    })
    .exec(&mut t)
    .await
    .unwrap();
    let cs = Comment::filter_by_video_id("a1").exec(&mut t).await.unwrap();
    assert_eq!(cs.len(), 1);
    assert_eq!(cs[0].timestamp_ms, Some(1500));
    Comment::filter_by_video_id("a1").delete().exec(&mut t).await.unwrap();
    Video::delete_by_id(&mut t, "a1").await.unwrap();
    assert!(Video::filter_by_slug("slugA")
        .first()
        .exec(&mut t)
        .await
        .unwrap()
        .is_none());
    let _ = v;
}
