//! Recording uploads end to end (public router, PostgreSQL as the app role, in-memory
//! store): per-account pending cap, byte reservations signed into part URLs, idempotent
//! completion, the completion body limit, poster/transcript publishing after upload and
//! the bounded reads behind the watch page and library.

use std::sync::Arc;
use std::time::Duration;

use easyshot_server::config::Config;
use easyshot_server::storage::{MemoryStore, ObjectStore};
use easyshot_server::video::service::COMPLETE_BODY_LIMIT;
use easyshot_server::{AppState, vals, web};
use http_body_util::BodyExt;
use serde_json::{Value, json};
use topcoat::router::{Body, Router, StatusCode, request::Request, response::Response};

mod common;

struct App {
    router: Router,
    store: Arc<MemoryStore>,
    t: common::TestDb,
}

struct Res {
    status: StatusCode,
    body: String,
}

impl Res {
    fn json(&self) -> Value {
        serde_json::from_str(&self.body).unwrap_or(Value::Null)
    }
    fn code(&self) -> String {
        self.json()["error"]["code"]
            .as_str()
            .unwrap_or("")
            .to_string()
    }
}

const MB: i64 = 1_000_000;

impl App {
    async fn new() -> App {
        App::with(|_| {}).await
    }

    async fn with(tweak: impl FnOnce(&mut Config)) -> App {
        let t = common::database().await;
        let store = Arc::new(MemoryStore::new());
        let mut config = t.config();
        tweak(&mut config);
        let state = AppState::new(t.app.clone(), store.clone(), config);
        App {
            router: web::router(state),
            store,
            t,
        }
    }

    async fn send(&self, req: Request) -> Res {
        let res: Response = self.router.handle(req).await;
        let (parts, body) = res.into_parts();
        let bytes = body.collect().await.unwrap().to_bytes();
        Res {
            status: parts.status,
            body: String::from_utf8_lossy(&bytes).into_owned(),
        }
    }

    async fn get(&self, path: &str) -> Res {
        let r = http::Request::builder().uri(path);
        self.send(r.body(Body::empty()).unwrap()).await
    }

    async fn raw(&self, path: &str, token: &str, body: String) -> Res {
        let r = http::Request::builder()
            .method("POST")
            .uri(path)
            .header("authorization", format!("Bearer {token}"))
            .header("content-type", "application/json");
        self.send(r.body(Body::from(body)).unwrap()).await
    }

    async fn api(&self, method: &str, path: &str, token: &str, body: Option<Value>) -> Res {
        let mut r = http::Request::builder()
            .method(method)
            .uri(path)
            .header("authorization", format!("Bearer {token}"));
        let body = match body {
            Some(b) => {
                r = r.header("content-type", "application/json");
                Body::from(b.to_string())
            }
            None => Body::empty(),
        };
        self.send(r.body(body).unwrap()).await
    }

    /// A new account (no mailer configured, so registration signs straight in).
    async fn user(&self, email: &str) -> String {
        let r = self
            .send(
                http::Request::builder()
                    .method("POST")
                    .uri("/v1/auth/register")
                    .header("content-type", "application/json")
                    .body(Body::from(
                        json!({"email": email, "password": "supersecret123"}).to_string(),
                    ))
                    .unwrap(),
            )
            .await;
        assert_eq!(r.status, StatusCode::CREATED, "{}", r.body);
        r.json()["token"].as_str().unwrap().to_string()
    }

    async fn create(&self, token: &str) -> Res {
        self.api("POST", "/v1/videos", token, Some(json!({}))).await
    }

    /// A pending video: (id, upload id, slug).
    async fn pending(&self, token: &str) -> (String, String, String) {
        let v = self.create(token).await;
        assert_eq!(v.status, StatusCode::CREATED, "{}", v.body);
        let v = v.json();
        let id = v["id"].as_str().unwrap().to_string();
        let upload = self
            .t
            .owner
            .query_one("SELECT upload_id FROM videos WHERE id = $1", &vals![&id])
            .await
            .unwrap()
            .text(0)
            .unwrap();
        (id, upload, v["slug"].as_str().unwrap().to_string())
    }

    async fn presign(&self, token: &str, id: &str, parts: &[(i64, i64)]) -> Res {
        let parts: Vec<Value> = parts
            .iter()
            .map(|(n, size)| json!({"part_number": n, "size": size}))
            .collect();
        self.api(
            "POST",
            &format!("/v1/videos/{id}/parts"),
            token,
            Some(json!({ "parts": parts })),
        )
        .await
    }

    async fn finish(&self, token: &str, id: &str, parts: &[(i32, &str)]) -> Res {
        let parts: Vec<Value> = parts
            .iter()
            .map(|(n, tag)| json!({"part_number": n, "etag": tag}))
            .collect();
        self.api(
            "POST",
            &format!("/v1/videos/{id}/complete"),
            token,
            Some(json!({"parts": parts, "duration_ms": 60_000})),
        )
        .await
    }

    /// Upload and complete a recording of the given part sizes; returns the video JSON.
    async fn ready(&self, token: &str, sizes: &[i64]) -> Value {
        let (id, upload, _) = self.pending(token).await;
        let wanted: Vec<(i64, i64)> = sizes
            .iter()
            .enumerate()
            .map(|(i, s)| (i as i64 + 1, *s))
            .collect();
        let r = self.presign(token, &id, &wanted).await;
        assert_eq!(r.status, StatusCode::OK, "{}", r.body);
        let tags: Vec<String> = sizes
            .iter()
            .enumerate()
            .map(|(i, s)| self.store.put_part(&upload, i as i32 + 1, *s))
            .collect();
        let parts: Vec<(i32, &str)> = tags
            .iter()
            .enumerate()
            .map(|(i, t)| (i as i32 + 1, t.as_str()))
            .collect();
        let done = self.finish(token, &id, &parts).await;
        assert_eq!(done.status, StatusCode::OK, "{}", done.body);
        done.json()
    }

    async fn reserved(&self, id: &str) -> i64 {
        self.t
            .owner
            .query_one(
                "SELECT COALESCE(SUM(byte_size), 0)::BIGINT FROM upload_parts WHERE video_id = $1",
                &vals![id],
            )
            .await
            .unwrap()
            .i64(0)
            .unwrap()
    }

    async fn status(&self, id: &str) -> String {
        self.t
            .owner
            .query_one("SELECT status FROM videos WHERE id = $1", &vals![id])
            .await
            .unwrap()
            .text(0)
            .unwrap()
    }
}

async fn open_stream(app: &App, path: &str) -> Body {
    let r = http::Request::builder()
        .uri(path)
        .header("datastar-request", "true");
    let res = app.router.handle(r.body(Body::empty()).unwrap()).await;
    assert_eq!(res.status(), StatusCode::OK);
    res.into_body()
}

async fn read_until(body: &mut Body, needle: &str, limit: Duration) -> String {
    let mut seen = String::new();
    let deadline = tokio::time::Instant::now() + limit;
    while !seen.contains(needle) {
        let left = deadline.saturating_duration_since(tokio::time::Instant::now());
        match tokio::time::timeout(left, body.frame()).await {
            Ok(Some(Ok(f))) => {
                if let Some(d) = f.data_ref() {
                    seen.push_str(&String::from_utf8_lossy(d));
                }
            }
            _ => break,
        }
    }
    seen
}

fn now() -> i64 {
    chrono::Utc::now().timestamp_millis()
}

/// The opening tag of the element with this id.
fn tag_of<'a>(html: &'a str, id: &str) -> &'a str {
    let at = html
        .find(&format!("id=\"{id}\""))
        .unwrap_or_else(|| panic!("no #{id} in {html}"));
    let start = html[..at].rfind('<').unwrap();
    let end = at + html[at..].find('>').unwrap();
    &html[start..=end]
}

#[tokio::test]
async fn pending_uploads_are_capped_per_account_even_when_concurrent() {
    let app = App::new().await;
    let token = app.user("cap@example.test").await;
    let other = app.user("other@example.test").await;
    let created = app.create(&token).await.json();
    assert_eq!(created["upload"]["max_parts"], 10_000);
    assert_eq!(created["upload"]["max_part_batch"], 100);

    // Six at once on top of one: exactly two more fit under the cap of three.
    let tries = (0..6).map(|_| app.create(&token));
    let results = futures_util::future::join_all(tries).await;
    let ok = results
        .iter()
        .filter(|r| r.status == StatusCode::CREATED)
        .count();
    assert_eq!(
        ok,
        2,
        "{:?}",
        results.iter().map(|r| &r.body).collect::<Vec<_>>()
    );
    for r in results.iter().filter(|r| r.status != StatusCode::CREATED) {
        assert_eq!(r.status, StatusCode::TOO_MANY_REQUESTS);
        assert_eq!(r.code(), "TOO_MANY_PENDING_UPLOADS");
    }
    // Refused creates leave no multipart upload behind; other accounts are unaffected.
    assert_eq!(app.store.open_uploads(), 3);
    assert_eq!(app.create(&other).await.status, StatusCode::CREATED);

    // Deleting one frees a slot.
    let id = created["id"].as_str().unwrap();
    let del = app
        .api("DELETE", &format!("/v1/videos/{id}"), &token, None)
        .await;
    assert_eq!(del.status, StatusCode::NO_CONTENT);
    let (id, upload, _) = app.pending(&token).await;
    assert_eq!(
        app.create(&token).await.status,
        StatusCode::TOO_MANY_REQUESTS
    );

    // Completing one frees a slot.
    assert_eq!(
        app.presign(&token, &id, &[(1, 10)]).await.status,
        StatusCode::OK
    );
    let tag = app.store.put_part(&upload, 1, 10);
    assert_eq!(
        app.finish(&token, &id, &[(1, &tag)]).await.status,
        StatusCode::OK
    );
    let (stale, _, _) = app.pending(&token).await;

    // An abandoned upload older than a day no longer counts (the expire job aborts it),
    // and its parts can no longer be requested.
    app.t
        .owner
        .execute(
            "UPDATE videos SET created_at = $2 WHERE id = $1",
            &vals![&stale, now() - 25 * 3_600_000],
        )
        .await
        .unwrap();
    assert_eq!(app.create(&token).await.status, StatusCode::CREATED);
    let r = app.presign(&token, &stale, &[(1, 10)]).await;
    assert_eq!(r.status, StatusCode::BAD_REQUEST, "{}", r.body);
    app.t.finish().await;
}

#[tokio::test]
async fn part_urls_sign_reserved_sizes() {
    let app = App::with(|c| c.max_video_bytes = 8 * MB).await;
    let token = app.user("parts@example.test").await;
    let (id, upload, _) = app.pending(&token).await;

    // Only the sized shape is accepted.
    let unsized_parts = app
        .api(
            "POST",
            &format!("/v1/videos/{id}/parts"),
            &token,
            Some(json!({"part_numbers": [1, 2]})),
        )
        .await;
    assert_eq!(unsized_parts.status, StatusCode::BAD_REQUEST);
    assert_eq!(unsized_parts.code(), "INVALID_REQUEST");
    assert_eq!(app.reserved(&id).await, 0);

    let r = app.presign(&token, &id, &[(1, 5 * MB), (2, 1000)]).await;
    assert_eq!(r.status, StatusCode::OK, "{}", r.body);
    let body = r.json();
    assert_eq!(body["expires_in"], 3600);
    let first = &body["parts"][0];
    assert_eq!(first["part_number"], 1);
    assert_eq!(first["method"], "PUT");
    assert_eq!(first["headers"]["content-length"], "5000000");
    assert!(
        first["url"]
            .as_str()
            .unwrap()
            .contains("partNumber=1&len=5000000")
    );
    assert_eq!(body["parts"][1]["headers"]["content-length"], "1000");
    assert_eq!(app.reserved(&id).await, 5 * MB + 1000);

    // The store refuses a body of another size than the one signed.
    assert!(app.store.try_put_part(&upload, 2, 1001).is_err());
    assert!(app.store.try_put_part(&upload, 2, 1000).is_ok());

    // Asking again for the same size is fine; a part's size never changes.
    assert_eq!(
        app.presign(&token, &id, &[(2, 1000)]).await.status,
        StatusCode::OK
    );
    let changed = app.presign(&token, &id, &[(2, 2000)]).await;
    assert_eq!(changed.status, StatusCode::BAD_REQUEST, "{}", changed.body);
    assert_eq!(app.store.signed_part_size(&upload, 2), Some(1000));

    // Bad requests.
    for (parts, status) in [
        (vec![(3, 0)], StatusCode::BAD_REQUEST),
        (vec![(3, -5)], StatusCode::BAD_REQUEST),
        (vec![(0, 10)], StatusCode::BAD_REQUEST),
        (vec![(10_001, 10)], StatusCode::BAD_REQUEST),
        (vec![(3, 10), (3, 10)], StatusCode::BAD_REQUEST),
        (vec![(3, 9 * MB)], StatusCode::PAYLOAD_TOO_LARGE),
        (
            (1..=101).map(|n| (n + 2, 1)).collect(),
            StatusCode::BAD_REQUEST,
        ),
    ] {
        let r = app.presign(&token, &id, &parts).await;
        assert_eq!(r.status, status, "{parts:?}: {}", r.body);
    }
    let missing = app
        .api(
            "POST",
            &format!("/v1/videos/{id}/parts"),
            &token,
            Some(json!({})),
        )
        .await;
    assert_eq!(missing.status, StatusCode::BAD_REQUEST);

    // Per video: 5 MB + 1000 reserved, so 3 MB more does not fit in 8 MB, and a refused
    // batch reserves nothing.
    let over = app.presign(&token, &id, &[(3, MB), (4, 2 * MB)]).await;
    assert_eq!(over.status, StatusCode::PAYLOAD_TOO_LARGE, "{}", over.body);
    assert_eq!(over.code(), "TOO_LARGE");
    assert_eq!(app.reserved(&id).await, 5 * MB + 1000);
    assert_eq!(
        app.presign(&token, &id, &[(3, 2 * MB)]).await.status,
        StatusCode::OK
    );

    // Another account cannot request parts of this upload.
    let other = app.user("other@example.test").await;
    let foreign = app.presign(&other, &id, &[(9, 10)]).await;
    assert_eq!(foreign.status, StatusCode::NOT_FOUND);
    app.t.finish().await;
}

#[tokio::test]
async fn account_budget_spans_unfinished_uploads_and_is_released_on_completion() {
    let app = App::with(|c| c.max_pending_upload_bytes = 10 * MB).await;
    let token = app.user("budget@example.test").await;
    let (a, upload_a, _) = app.pending(&token).await;
    let (b, _, _) = app.pending(&token).await;
    let (c, _, _) = app.pending(&token).await;

    // Concurrent requests on three uploads: only one 6 MB reservation fits in 10 MB.
    let tries = [&a, &b, &c].map(|id| app.presign(&token, id, &[(1, 6 * MB)]));
    let results = futures_util::future::join_all(tries).await;
    let statuses: Vec<_> = results.iter().map(|r| r.status).collect();
    assert_eq!(
        statuses.iter().filter(|s| **s == StatusCode::OK).count(),
        1,
        "{statuses:?}"
    );
    assert_eq!(
        statuses
            .iter()
            .filter(|s| **s == StatusCode::PAYLOAD_TOO_LARGE)
            .count(),
        2
    );
    let total = app.reserved(&a).await + app.reserved(&b).await + app.reserved(&c).await;
    assert_eq!(total, 6 * MB);

    // Make `a` the one holding the reservation, then fill the account up.
    let holder = [&a, &b, &c]
        .into_iter()
        .zip(&statuses)
        .find(|(_, s)| **s == StatusCode::OK)
        .unwrap()
        .0
        .clone();
    if holder != a {
        let del = app
            .api("DELETE", &format!("/v1/videos/{holder}"), &token, None)
            .await;
        assert_eq!(del.status, StatusCode::NO_CONTENT);
        assert_eq!(
            app.reserved(&holder).await,
            0,
            "purge releases the reservation"
        );
        assert_eq!(
            app.presign(&token, &a, &[(1, 6 * MB)]).await.status,
            StatusCode::OK
        );
    }
    let rest = if b != holder { &b } else { &c };
    assert_eq!(
        app.presign(&token, rest, &[(1, 4 * MB)]).await.status,
        StatusCode::OK
    );
    assert_eq!(
        app.presign(&token, rest, &[(2, 1)]).await.status,
        StatusCode::PAYLOAD_TOO_LARGE
    );

    // Completing `a` releases its 6 MB.
    let tag = app.store.put_part(&upload_a, 1, 6 * MB);
    let done = app.finish(&token, &a, &[(1, &tag)]).await;
    assert_eq!(done.status, StatusCode::OK, "{}", done.body);
    assert_eq!(done.json()["byte_size"], 6 * MB);
    assert_eq!(app.reserved(&a).await, 0);
    assert_eq!(
        app.presign(&token, rest, &[(2, 6 * MB)]).await.status,
        StatusCode::OK
    );
    app.t.finish().await;
}

#[tokio::test]
async fn completion_checks_reservations_and_recovers_idempotently() {
    let app = App::new().await;
    let token = app.user("finish@example.test").await;
    let (id, upload, _) = app.pending(&token).await;
    let key = app
        .t
        .owner
        .query_one("SELECT object_key FROM videos WHERE id = $1", &vals![&id])
        .await
        .unwrap()
        .text(0)
        .unwrap();
    assert_eq!(
        app.presign(&token, &id, &[(1, 6 * MB), (2, 500)])
            .await
            .status,
        StatusCode::OK
    );
    let t1 = app.store.put_part(&upload, 1, 6 * MB);
    let t2 = app.store.put_part(&upload, 2, 500);

    // ETag grammar and reservations are checked before storage is asked.
    for tag in [
        "",
        "\"\"",
        "not valid!",
        "\"unbalanced",
        &format!("\"{}\"", "a".repeat(65)),
    ] {
        let r = app.finish(&token, &id, &[(1, tag)]).await;
        assert_eq!(r.status, StatusCode::BAD_REQUEST, "{tag}: {}", r.body);
    }
    let r = app.finish(&token, &id, &[(1, &t1), (3, "\"abc\"")]).await;
    assert_eq!(r.status, StatusCode::BAD_REQUEST);
    assert!(r.body.contains("never requested"), "{}", r.body);

    // Storage assembled both parts, then the server died before the row changed.
    app.store
        .complete_multipart(&key, &upload, &[(1, t1.clone()), (2, t2.clone())])
        .await
        .unwrap();
    // A retry naming other parts than were assembled does not match: 409, still pending.
    let r = app.finish(&token, &id, &[(1, &t1)]).await;
    assert_eq!(r.status, StatusCode::CONFLICT, "{}", r.body);
    assert_eq!(r.code(), "NOT_UPLOADED");
    assert_eq!(app.status(&id).await, "pending");
    // The real retry finishes the transition, and later ones return the ready video.
    for _ in 0..2 {
        let r = app.finish(&token, &id, &[(2, &t2), (1, &t1)]).await;
        assert_eq!(r.status, StatusCode::OK, "{}", r.body);
        assert_eq!(r.json()["status"], "ready");
        assert_eq!(r.json()["byte_size"], 6 * MB + 500);
    }
    assert_eq!(app.reserved(&id).await, 0);
    let upload_id: Option<String> = app
        .t
        .owner
        .query_one("SELECT upload_id FROM videos WHERE id = $1", &vals![&id])
        .await
        .unwrap()
        .opt_text(0)
        .unwrap();
    assert!(upload_id.is_none());

    // An upload that was aborted (nothing assembled) answers 409, not a storage error.
    let (id, upload, _) = app.pending(&token).await;
    assert_eq!(
        app.presign(&token, &id, &[(1, 10)]).await.status,
        StatusCode::OK
    );
    let tag = app.store.put_part(&upload, 1, 10);
    app.store.abort_multipart("ignored", &upload).await.unwrap();
    let r = app.finish(&token, &id, &[(1, &tag)]).await;
    assert_eq!(r.status, StatusCode::CONFLICT, "{}", r.body);
    assert_eq!(app.status(&id).await, "pending");
    app.t.finish().await;
}

#[tokio::test]
async fn completion_accepts_a_full_manifest_but_not_more() {
    let app = App::new().await;
    let token = app.user("manifest@example.test").await;
    let (id, _, _) = app.pending(&token).await;
    let path = format!("/v1/videos/{id}/complete");
    // 10,000 parts with the longest accepted ETag, pretty-printed: under the route's limit.
    let parts: Vec<Value> = (1..=10_000)
        .map(|n| json!({"part_number": n, "etag": format!("\"{}\"", "f".repeat(64))}))
        .collect();
    let body = serde_json::to_string_pretty(&json!({"parts": parts, "duration_ms": 1})).unwrap();
    assert!(
        body.len() > 1024 * 1024 && body.len() < COMPLETE_BODY_LIMIT,
        "{}",
        body.len()
    );
    let r = app.raw(&path, &token, body).await;
    assert_eq!(r.status, StatusCode::BAD_REQUEST, "{}", r.body);
    assert!(r.body.contains("never requested"), "{}", r.body);
    // Beyond the limit: 413 before parsing.
    let r = app
        .raw(
            &path,
            &token,
            format!("{{\"parts\":\"{}\"}}", "x".repeat(COMPLETE_BODY_LIMIT)),
        )
        .await;
    assert_eq!(r.status, StatusCode::PAYLOAD_TOO_LARGE);
    // Other endpoints keep the small default.
    let r = app
        .raw(
            &format!("/v1/videos/{id}/progress"),
            &token,
            format!("{{\"x\":\"{}\"}}", "x".repeat(70 * 1024)),
        )
        .await;
    assert_eq!(r.status, StatusCode::PAYLOAD_TOO_LARGE);
    app.t.finish().await;
}

#[tokio::test]
async fn assets_publish_only_after_upload_and_reach_open_pages() {
    let app = App::new().await;
    let token = app.user("assets@example.test").await;
    let v = app.ready(&token, &[MB]).await;
    let (id, slug) = (v["id"].as_str().unwrap(), v["slug"].as_str().unwrap());

    // The page always has the transcript region, hidden while there is none.
    let page = app.get(&format!("/v/{slug}")).await;
    assert!(
        tag_of(&page.body, "transcript-card").contains("hidden"),
        "{}",
        page.body
    );
    assert!(!tag_of(&page.body, "player").contains("data-captions"));
    let mut live = open_stream(&app, &format!("/v/{slug}/live?since={}", now())).await;
    // The first stream starts the hub's LISTEN connection, whose resync renders everything.
    read_until(&mut live, "id=\"reactions\"", Duration::from_secs(3)).await;

    // Presigning publishes nothing.
    let put = |kind: &'static str, size: i64| {
        let path = format!("/v1/videos/{id}/{kind}");
        let token = token.clone();
        let app = &app;
        async move {
            let r = app
                .api("POST", &path, &token, Some(json!({"byte_size": size})))
                .await;
            assert_eq!(r.status, StatusCode::OK, "{}", r.body);
            let url = r.json()["upload"]["url"].as_str().unwrap().to_string();
            url.strip_prefix("https://store.test/put/")
                .unwrap()
                .split('?')
                .next()
                .unwrap()
                .to_string()
        }
    };
    let thumb = put("thumbnail", 2000).await;
    let vtt = put("transcript", 60).await;
    let keys = app
        .t
        .owner
        .query_one(
            "SELECT thumbnail_key, transcript_key FROM videos WHERE id = $1",
            &vals![id],
        )
        .await
        .unwrap();
    assert!(keys.opt_text(0).unwrap().is_none() && keys.opt_text(1).unwrap().is_none());

    // Completing before the PUT, or with the wrong type: 409, and the object is gone.
    let done = |kind: &'static str| {
        let path = format!("/v1/videos/{id}/{kind}/complete");
        let (app, token) = (&app, &token);
        async move { app.api("POST", &path, token, None).await }
    };
    let r = done("thumbnail").await;
    assert_eq!(
        (r.status, r.code()),
        (StatusCode::CONFLICT, "NOT_UPLOADED".into())
    );
    app.store.put(&thumb, 2000, "image/png");
    assert_eq!(done("thumbnail").await.status, StatusCode::CONFLICT);
    assert!(!app.store.contains(&thumb));
    app.store.put(&thumb, 3 * 1024 * 1024, "image/jpeg");
    assert_eq!(done("thumbnail").await.status, StatusCode::CONFLICT);

    // A late transcript appears on the open page: the card shows, the player gets captions.
    app.store.put_bytes(
        &vtt,
        b"WEBVTT\n\n00:00.000 --> 00:02.000\nHello\n",
        "text/vtt",
    );
    let r = done("transcript").await;
    assert_eq!(r.status, StatusCode::OK, "{}", r.body);
    assert_eq!(r.json()["has_transcript"], true);
    assert_eq!(r.json()["id"], id);
    let seen = read_until(&mut live, "transcript-card", Duration::from_secs(5)).await;
    assert!(
        !tag_of(&seen, "transcript-card").contains("hidden"),
        "{seen}"
    );
    assert!(
        tag_of(&seen, "player").contains(&format!("data-captions=\"/v/{slug}/transcript.vtt\"")),
        "{seen}"
    );
    // The list stays client-owned across patches.
    assert!(tag_of(&seen, "transcript").contains("data-ignore-morph"));

    // A late poster reaches the player host too.
    app.store.put(&thumb, 2000, "image/jpeg");
    let r = done("thumbnail").await;
    assert_eq!(r.status, StatusCode::OK, "{}", r.body);
    assert_eq!(r.json()["has_thumbnail"], true);
    let seen = read_until(&mut live, "data-poster", Duration::from_secs(5)).await;
    assert!(
        tag_of(&seen, "player").contains(&format!("data-poster=\"/v/{slug}/thumbnail.jpg\"")),
        "{seen}"
    );
    let page = app.get(&format!("/v/{slug}")).await;
    assert!(!tag_of(&page.body, "transcript-card").contains("hidden"));
    assert!(
        page.body
            .contains(&format!("poster=\"/v/{slug}/thumbnail.jpg\""))
    );
    app.t.finish().await;
}

#[tokio::test]
async fn progress_ticks_patch_only_the_player() {
    let app = App::new().await;
    let token = app.user("ticks@example.test").await;
    let (id, _, slug) = app.pending(&token).await;
    let mut live = open_stream(&app, &format!("/v/{slug}/live?since={}", now())).await;
    // The first stream starts the hub's LISTEN connection, whose resync renders everything.
    read_until(&mut live, "id=\"reactions\"", Duration::from_secs(3)).await;
    let r = app
        .api(
            "POST",
            &format!("/v1/videos/{id}/progress"),
            &token,
            Some(json!({"uploaded_bytes": 3 * MB, "recording": true})),
        )
        .await;
    assert_eq!(r.status, StatusCode::NO_CONTENT);
    let seen = read_until(&mut live, "MB uploaded", Duration::from_secs(5)).await;
    assert!(seen.contains("id=\"player-region\""), "{seen}");
    for other in ["video-head", "comments", "reactions", "transcript-card"] {
        assert!(
            !seen.contains(&format!("id=\"{other}\"")),
            "{other}: {seen}"
        );
    }
    app.t.finish().await;
}

#[tokio::test]
async fn library_comments_and_markers_are_bounded_in_the_query() {
    let app = App::new().await;
    let token = app.user("lists@example.test").await;
    let v = app.ready(&token, &[MB]).await;
    let (id, slug) = (v["id"].as_str().unwrap(), v["slug"].as_str().unwrap());
    let user = app
        .t
        .owner
        .query_one("SELECT user_id FROM videos WHERE id = $1", &vals![id])
        .await
        .unwrap()
        .text(0)
        .unwrap();
    let o = &app.t.owner;
    o.execute(
        "INSERT INTO item_comments (id, item_id, owner_id, author_name, body, timestamp_ms, created_at) \
         SELECT 'c' || i, $1, $2, 'guest', 'comment ' || i, NULL, 1000 + i FROM generate_series(0, 504) i",
        &vals![id, user.as_str()],
    )
    .await
    .unwrap();
    o.execute(
        "INSERT INTO item_reactions (id, item_id, owner_id, emoji, timestamp_ms, created_at) \
         SELECT 'r' || i, $1, $2, '🎉', CASE WHEN i % 2 = 0 THEN 1000 ELSE NULL END, 1000 + i \
         FROM generate_series(0, 1009) i",
        &vals![id, user.as_str()],
    )
    .await
    .unwrap();
    let page = app.get(&format!("/v/{slug}")).await;
    assert_eq!(page.status, StatusCode::OK);
    // The latest 500 comments, oldest of them first.
    assert!(page.body.contains("id=\"c-c504\"") && page.body.contains("id=\"c-c5\""));
    assert!(!page.body.contains("id=\"c-c4\""));
    assert!(page.body.find("id=\"c-c5\"").unwrap() < page.body.find("id=\"c-c504\"").unwrap());
    // 505 timestamped reactions: the latest 500 become markers; totals count all 1010.
    assert_eq!(page.body.matches("class=\"marker emoji\"").count(), 500);
    assert!(
        page.body.contains("<span class=\"count\">1010</span>"),
        "{}",
        page.body
    );

    // The library: newest first, expired ones left out, limit in the query.
    o.execute(
        "INSERT INTO videos (id, user_id, slug, title, status, object_key, content_type, created_at, updated_at, expires_at) \
         SELECT 'lib' || i, $1, 'lib' || i, 'Lib ' || i, 'ready', 'k', 'video/mp4', 10 + i, 10 + i, \
                CASE WHEN i = 205 THEN 1 ELSE 9999999999999 END \
         FROM generate_series(0, 205) i",
        &vals![user.as_str()],
    )
    .await
    .unwrap();
    let list = app.api("GET", "/v1/videos", &token, None).await.json();
    let items = list["items"].as_array().unwrap();
    assert_eq!(items.len(), 200);
    assert_eq!(items[0]["id"], id, "the real recording is the newest");
    assert_eq!(items[1]["id"], "lib204");
    assert!(items.iter().all(|i| i["id"] != "lib205"));
    app.t.finish().await;
}
