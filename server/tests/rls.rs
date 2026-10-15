//! Row-level security is a second wall: these tests run deliberately unfiltered SQL as the
//! app role (`easyshot_app`, NOBYPASSRLS) and check that PostgreSQL itself denies
//! cross-owner, cross-workspace and out-of-share access, both through raw SQL (`Db`) and inside
//! Toasty transactions.

use easyshot_server::db::{Context, Db, DbError};
use easyshot_server::orm;
use easyshot_server::vals;
use easyshot_server::video::model::Video;
use uuid::Uuid;

mod common;

async fn video(owner: &Db, id: &str, user: &str, slug: &str, workspace: Option<&str>) {
    owner
        .execute(
            "INSERT INTO videos (id, user_id, workspace_id, slug, title, status, object_key, content_type, \
             created_at, updated_at, expires_at) VALUES ($1, $2, $3, $4, 'original', 'ready', $5, 'video/mp4', 1, 1, 9999999999999)",
            &vals![id, user, workspace, slug, format!("v/{id}.mp4")],
        )
        .await
        .unwrap();
}

async fn comment(owner: &Db, item: &str) {
    owner
        .execute(
            "INSERT INTO item_comments (id, item_id, author_name, body, created_at) VALUES ($1, $2, 'x', 'hi', 1)",
            &vals![Uuid::new_v4(), item],
        )
        .await
        .unwrap();
}

async fn ids(db: &Db, sql: &str) -> Vec<String> {
    let mut v: Vec<String> = db
        .query(sql, &[])
        .await
        .unwrap()
        .iter()
        .map(|r| r.text(0).unwrap())
        .collect();
    v.sort();
    v
}

async fn title(owner: &Db, id: &str) -> String {
    owner
        .query_one("SELECT title FROM videos WHERE id = $1", &vals![id])
        .await
        .unwrap()
        .text(0)
        .unwrap()
}

fn rls_violation(e: DbError) -> bool {
    e.to_string().contains("row-level security")
}

#[tokio::test]
async fn database_denies_cross_owner_access_without_app_filters() {
    let t = common::database().await;
    let (a, b) = (Uuid::new_v4(), Uuid::new_v4());
    video(&t.owner, "va", &a.to_string(), "slugA", None).await;
    video(&t.owner, "vb", &b.to_string(), "slugB", None).await;
    comment(&t.owner, "va").await;
    comment(&t.owner, "vb").await;
    t.owner
        .execute(
            "INSERT INTO screenshots (id, user_id, slug, object_key, content_type, byte_size, created_at, expires_at) \
             VALUES ($1, $2, 'shotA', 'k', 'image/png', 1, 1, 9999999999999)",
            &vals![Uuid::new_v4(), a],
        )
        .await
        .unwrap();

    // No context at all: owner-scoped tables are empty to the app role.
    for table in ["videos", "item_comments", "screenshots"] {
        assert!(
            ids(&t.app, &format!("SELECT id FROM {table}"))
                .await
                .is_empty(),
            "{table}"
        );
    }

    // B's context with queries that forget the owner filter.
    let as_b = t.app.scoped(Context::user(b));
    assert_eq!(ids(&as_b, "SELECT id FROM videos").await, ["vb"]);
    assert_eq!(
        ids(&as_b, "SELECT item_id FROM item_comments").await,
        ["vb"]
    );
    assert!(ids(&as_b, "SELECT id FROM screenshots").await.is_empty());
    assert_eq!(
        as_b.execute("UPDATE videos SET title = 'pwned'", &[])
            .await
            .unwrap(),
        1
    );
    assert_eq!(title(&t.owner, "va").await, "original");
    assert_eq!(
        as_b.execute("DELETE FROM item_comments", &[])
            .await
            .unwrap(),
        1
    );
    assert_eq!(
        ids(&t.owner, "SELECT item_id FROM item_comments").await,
        ["va"]
    );
    assert_eq!(
        as_b.execute("DELETE FROM videos WHERE id = 'va'", &[])
            .await
            .unwrap(),
        0
    );

    // Writes on behalf of someone else fail WITH CHECK.
    let e = as_b
        .execute(
            "INSERT INTO videos (id, user_id, slug, title, object_key, content_type, created_at, updated_at, expires_at) \
             VALUES ('forged', $1, 'forged', 't', 'k', 'video/mp4', 1, 1, 2)",
            &vals![a],
        )
        .await
        .unwrap_err();
    assert!(rls_violation(e));
    let e = as_b
        .execute(
            "INSERT INTO item_comments (id, item_id, author_name, body, created_at) VALUES ('c', 'va', 'x', 'y', 1)",
            &[],
        )
        .await
        .unwrap_err();
    assert!(rls_violation(e));
    let e = as_b
        .execute("UPDATE videos SET user_id = $1 WHERE id = 'vb'", &vals![a])
        .await
        .unwrap_err();
    assert!(rls_violation(e), "ownership cannot be handed away");

    // The owner still has full access.
    let as_a = t.app.scoped(Context::user(a));
    assert_eq!(ids(&as_a, "SELECT id FROM videos").await, ["va"]);
    assert_eq!(ids(&as_a, "SELECT slug FROM screenshots").await, ["shotA"]);
    t.finish().await;
}

#[tokio::test]
async fn database_isolates_workspaces() {
    let t = common::database().await;
    let (owner1, owner2, member) = (Uuid::new_v4(), Uuid::new_v4(), Uuid::new_v4());
    video(&t.owner, "w1", &owner1.to_string(), "slugW1", Some("ws-1")).await;
    video(&t.owner, "w2", &owner2.to_string(), "slugW2", Some("ws-2")).await;
    comment(&t.owner, "w1").await;
    comment(&t.owner, "w2").await;
    let in_ws1 = t.app.scoped(Context {
        workspace_id: Some("ws-1".into()),
        ..Context::user(member)
    });
    assert_eq!(ids(&in_ws1, "SELECT id FROM videos").await, ["w1"]);
    assert_eq!(
        ids(&in_ws1, "SELECT item_id FROM item_comments").await,
        ["w1"]
    );
    assert_eq!(
        in_ws1
            .execute("UPDATE videos SET title = 'x' WHERE id = 'w2'", &[])
            .await
            .unwrap(),
        0
    );
    let e = in_ws1
        .execute(
            "UPDATE videos SET workspace_id = 'ws-2' WHERE id = 'w1'",
            &[],
        )
        .await
        .unwrap_err();
    assert!(
        rls_violation(e),
        "items cannot be moved into another workspace"
    );
    let in_ws2 = t.app.scoped(Context {
        workspace_id: Some("ws-2".into()),
        ..Context::user(member)
    });
    assert_eq!(ids(&in_ws2, "SELECT id FROM videos").await, ["w2"]);
    // A member of no workspace sees neither.
    assert!(
        ids(
            &t.app.scoped(Context::user(member)),
            "SELECT id FROM videos"
        )
        .await
        .is_empty()
    );
    t.finish().await;
}

#[tokio::test]
async fn share_path_exposes_exactly_one_item_read_only() {
    let t = common::database().await;
    let (a, b) = (Uuid::new_v4(), Uuid::new_v4());
    video(&t.owner, "va", &a.to_string(), "slugA", None).await;
    video(&t.owner, "vb", &b.to_string(), "slugB", None).await;
    comment(&t.owner, "va").await;
    comment(&t.owner, "vb").await;

    let lookup = t.app.scoped(Context {
        share_slug: Some("slugA".into()),
        ..Context::default()
    });
    assert_eq!(ids(&lookup, "SELECT id FROM videos").await, ["va"]);
    assert!(
        ids(&lookup, "SELECT item_id FROM item_comments")
            .await
            .is_empty()
    );
    assert_eq!(
        lookup
            .execute("UPDATE videos SET title = 'x'", &[])
            .await
            .unwrap(),
        0
    );
    assert_eq!(lookup.execute("DELETE FROM videos", &[]).await.unwrap(), 0);

    let viewer = t.app.scoped(Context {
        share_slug: Some("slugA".into()),
        share_item_id: Some("va".into()),
        ..Context::default()
    });
    assert_eq!(
        ids(&viewer, "SELECT item_id FROM item_comments").await,
        ["va"]
    );
    viewer
        .execute(
            "INSERT INTO item_comments (id, item_id, author_name, body, created_at) VALUES ('ok', 'va', 'g', 'hi', 1)",
            &[],
        )
        .await
        .unwrap();
    let e = viewer
        .execute(
            "INSERT INTO item_comments (id, item_id, author_name, body, created_at) VALUES ('no', 'vb', 'g', 'hi', 1)",
            &[],
        )
        .await
        .unwrap_err();
    assert!(rls_violation(e));
    assert_eq!(
        viewer
            .execute("DELETE FROM item_comments", &[])
            .await
            .unwrap(),
        0
    );

    // An item id that does not belong to the shared slug opens nothing.
    let mismatched = t.app.scoped(Context {
        share_slug: Some("slugA".into()),
        share_item_id: Some("vb".into()),
        ..Context::default()
    });
    assert!(
        ids(&mismatched, "SELECT item_id FROM item_comments")
            .await
            .is_empty()
    );
    t.finish().await;
}

#[tokio::test]
async fn toasty_transactions_carry_the_rls_context() {
    let t = common::database().await;
    let (a, b) = (Uuid::new_v4(), Uuid::new_v4());
    video(&t.owner, "va", &a.to_string(), "slugA", None).await;
    video(&t.owner, "vb", &b.to_string(), "slugB", None).await;
    let mut db = t.app.toasty();

    // B asks Toasty for A's videos: the query is "correct" for A but runs as B.
    let mut tx = orm::begin(&mut db, &Context::user(b)).await.unwrap();
    let found = Video::filter_by_user_id(a.to_string())
        .exec(&mut tx)
        .await
        .unwrap();
    assert!(found.is_empty());
    let visible = toasty::sql::query("SELECT id FROM videos")
        .exec(&mut tx)
        .await
        .unwrap();
    assert_eq!(visible.len(), 1);
    let _ = Video::update_by_id("va").title("pwned").exec(&mut tx).await;
    tx.commit().await.unwrap();
    assert_eq!(title(&t.owner, "va").await, "original");

    // Positive control: the same query as A sees the row, so the context was applied.
    let mut tx = orm::begin(&mut db, &Context::user(a)).await.unwrap();
    let found = Video::filter_by_user_id(a.to_string())
        .exec(&mut tx)
        .await
        .unwrap();
    assert_eq!(found.len(), 1);
    tx.commit().await.unwrap();

    // Without a transaction context nothing is visible.
    let none = Video::filter_by_user_id(a.to_string())
        .exec(&mut db)
        .await
        .unwrap();
    assert!(none.is_empty());
    t.finish().await;
}

#[tokio::test]
async fn maintenance_bypass_reaches_every_owner() {
    let t = common::database().await;
    video(&t.owner, "va", &Uuid::new_v4().to_string(), "slugA", None).await;
    video(&t.owner, "vb", &Uuid::new_v4().to_string(), "slugB", None).await;
    let m = t.app.scoped(Context::maintenance());
    assert_eq!(ids(&m, "SELECT id FROM videos").await, ["va", "vb"]);
    t.finish().await;
}

#[tokio::test]
async fn production_verify_reports_the_rls_posture() {
    let t = common::database().await;
    let checks = easyshot_server::prod::verify(&t.owner_url, &t.app_url)
        .await
        .unwrap();
    let failed: Vec<_> = checks
        .iter()
        .filter(|(_, ok)| !ok)
        .map(|(w, _)| w.as_str())
        .collect();
    // The test cluster uses the development password on purpose; everything else holds.
    assert_eq!(
        failed,
        ["app role does not use the development password"],
        "{checks:?}"
    );
    assert!(checks.iter().any(|(w, ok)| w.starts_with("videos:") && *ok));
    // Pointing the "app" URL at the owner (a superuser) fails the role checks.
    let checks = easyshot_server::prod::verify(&t.owner_url, &t.owner_url)
        .await
        .unwrap();
    assert!(checks.iter().any(|(w, ok)| w.contains("bypass") && !ok));
    t.finish().await;
}
