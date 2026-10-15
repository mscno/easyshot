//! The public router (Topcoat host + mounted axum API) end to end, against PostgreSQL as the
//! app role and the in-memory object store: video upload API, watch page, comments,
//! reactions, privacy, live updates, oEmbed, email-code sign-in and the library.

use std::sync::Arc;
use std::time::Duration;

use easyshot_server::mailer::MemoryMailer;
use easyshot_server::storage::MemoryStore;
use easyshot_server::{AppState, vals, web};
use http_body_util::BodyExt;
use serde_json::{Value, json};
use topcoat::router::{Body, Router, StatusCode, request::Request, response::Response};

mod common;

struct App {
    router: Router,
    store: Arc<MemoryStore>,
    mail: Arc<MemoryMailer>,
    t: common::TestDb,
}

struct Res {
    status: StatusCode,
    headers: topcoat::router::HeaderMap,
    body: String,
}

impl Res {
    fn json(&self) -> Value {
        serde_json::from_str(&self.body).unwrap_or(Value::Null)
    }
    fn header(&self, name: &str) -> &str {
        self.headers
            .get(name)
            .and_then(|v| v.to_str().ok())
            .unwrap_or("")
    }
    /// `name=value` of a Set-Cookie header whose name contains `part`.
    fn cookie(&self, part: &str) -> Option<String> {
        self.headers
            .get_all("set-cookie")
            .iter()
            .filter_map(|v| v.to_str().ok())
            .find(|c| c.contains(part))
            .map(|c| c.split(';').next().unwrap().to_string())
    }
}

impl App {
    async fn new() -> App {
        let t = common::database().await;
        let store = Arc::new(MemoryStore::new());
        let mail = MemoryMailer::new();
        let state =
            AppState::new(t.app.clone(), store.clone(), t.config()).with_mailer(mail.clone());
        App {
            router: web::router(state),
            store,
            mail,
            t,
        }
    }

    async fn send(&self, req: Request) -> Res {
        let res: Response = self.router.handle(req).await;
        let (parts, body) = res.into_parts();
        let bytes = body.collect().await.unwrap().to_bytes();
        Res {
            status: parts.status,
            headers: parts.headers,
            body: String::from_utf8_lossy(&bytes).into_owned(),
        }
    }

    async fn get(&self, path: &str, cookie: Option<&str>) -> Res {
        let mut r = http::Request::builder().uri(path);
        if let Some(c) = cookie {
            r = r.header("cookie", c);
        }
        self.send(r.body(Body::empty()).unwrap()).await
    }

    async fn api(&self, method: &str, path: &str, token: Option<&str>, body: Option<Value>) -> Res {
        let mut r = http::Request::builder().method(method).uri(path);
        if let Some(t) = token {
            r = r.header("authorization", format!("Bearer {t}"));
        }
        let body = match body {
            Some(b) => {
                r = r.header("content-type", "application/json");
                Body::from(b.to_string())
            }
            None => Body::empty(),
        };
        self.send(r.body(body).unwrap()).await
    }

    /// A form post; `datastar` adds the request header Datastar sends.
    async fn form(
        &self,
        path: &str,
        fields: &[(&str, &str)],
        cookie: Option<&str>,
        datastar: bool,
    ) -> Res {
        let body = fields
            .iter()
            .map(|(k, v)| format!("{}={}", enc(k), enc(v)))
            .collect::<Vec<_>>()
            .join("&");
        let mut r = http::Request::builder()
            .method("POST")
            .uri(path)
            .header("content-type", "application/x-www-form-urlencoded");
        if let Some(c) = cookie {
            r = r.header("cookie", c);
        }
        if datastar {
            r = r.header("datastar-request", "true");
        }
        self.send(r.body(Body::from(body)).unwrap()).await
    }

    async fn user(&self, email: &str) -> String {
        let r = self
            .api(
                "POST",
                "/v1/auth/register",
                None,
                Some(json!({"email": email, "password": "supersecret123"})),
            )
            .await;
        assert_eq!(r.status, StatusCode::CREATED, "{}", r.body);
        r.json()["token"].as_str().unwrap().to_string()
    }

    /// Create a video and finish its two-part upload; returns the API JSON.
    async fn ready_video(&self, token: &str, title: &str) -> Value {
        let v = self
            .api(
                "POST",
                "/v1/videos",
                Some(token),
                Some(json!({"title": title})),
            )
            .await;
        assert_eq!(v.status, StatusCode::CREATED, "{}", v.body);
        let v = v.json();
        let id = v["id"].as_str().unwrap();
        let parts = self
            .api(
                "POST",
                &format!("/v1/videos/{id}/parts"),
                Some(token),
                Some(json!({"part_numbers": [1, 2]})),
            )
            .await
            .json();
        let upload_id = upload_id(parts["parts"][0]["url"].as_str().unwrap());
        let e1 = self.store.put_part(&upload_id, 1, 5 * 1024 * 1024);
        let e2 = self.store.put_part(&upload_id, 2, 1000);
        let done = self
            .api(
                "POST",
                &format!("/v1/videos/{id}/complete"),
                Some(token),
                Some(json!({
                    "parts": [{"part_number": 2, "etag": e2}, {"part_number": 1, "etag": e1}],
                    "duration_ms": 60_000, "width": 1920, "height": 1080
                })),
            )
            .await;
        assert_eq!(done.status, StatusCode::OK, "{}", done.body);
        done.json()
    }

    /// Sign in through the web form with the emailed code; returns the session cookie.
    async fn web_login(&self, email: &str) -> String {
        let r = self
            .form(
                "/login",
                &[("email", email), ("next", "/library")],
                None,
                false,
            )
            .await;
        assert_eq!(r.status, StatusCode::OK);
        assert!(r.body.contains("name=\"code\""), "{}", r.body);
        let code = self.code_for(email).await;
        let r = self
            .form(
                "/login/verify",
                &[("email", email), ("code", &code), ("next", "/library")],
                None,
                false,
            )
            .await;
        assert_eq!(r.status, StatusCode::SEE_OTHER, "{}", r.body);
        assert_eq!(r.header("location"), "/library");
        r.cookie("sg_session").expect("session cookie")
    }

    async fn code_for(&self, email: &str) -> String {
        for _ in 0..50 {
            if let Some(m) = self
                .mail
                .sent()
                .into_iter()
                .rev()
                .find(|m| m.to == email && m.subject.contains("sign-in code"))
            {
                return m
                    .text
                    .split_whitespace()
                    .find(|w| w.len() == 6 && w.bytes().all(|b| b.is_ascii_digit()))
                    .unwrap()
                    .to_string();
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        panic!("no code mailed to {email}");
    }
}

fn enc(s: &str) -> String {
    s.bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                (b as char).to_string()
            }
            b' ' => "+".into(),
            _ => format!("%{b:02X}"),
        })
        .collect()
}

fn upload_id(part_url: &str) -> String {
    part_url
        .split("uploadId=")
        .nth(1)
        .unwrap()
        .split('&')
        .next()
        .unwrap()
        .to_string()
}

fn slug_of(v: &Value) -> String {
    v["slug"].as_str().unwrap().to_string()
}

/// Read SSE frames until one contains `needle` or `limit` passes; returns what was read.
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

#[tokio::test]
async fn live_updates_cross_server_instances() {
    // Instance A serves the writer; instance B, with its own pool and LISTEN connection,
    // serves a viewer. Nothing is shared between them but the database.
    let a = App::new().await;
    let pool_b = easyshot_server::db::Db::connect_url(&a.t.app_url, 3)
        .await
        .unwrap();
    let b = web::router(AppState::new(pool_b, a.store.clone(), a.t.config()));
    let token = a.user("owner@example.com").await;
    let v = a.ready_video(&token, "Cross").await;
    let slug = slug_of(&v);

    // `since` = now: no snapshot on open, so everything below arrives through NOTIFY.
    let now = chrono::Utc::now().timestamp_millis();
    let live = b
        .handle(
            http::Request::builder()
                .uri(format!("/v/{slug}/live?since={now}"))
                .header("datastar-request", "true")
                .body(Body::empty())
                .unwrap(),
        )
        .await;
    assert_eq!(live.status(), StatusCode::OK);
    let mut body = live.into_body();
    // B's listener connects and sends one resync render.
    let resync = read_until(&mut body, "datastar-patch-elements", Duration::from_secs(5)).await;
    assert!(resync.contains("datastar-patch-elements"), "{resync}");

    let started = std::time::Instant::now();
    let r = a
        .form(
            &format!("/v/{slug}/comments"),
            &[("body", "from instance A"), ("name", "Ann")],
            None,
            true,
        )
        .await;
    assert_eq!(r.status, StatusCode::OK, "{}", r.body);
    let seen = read_until(&mut body, "from instance A", Duration::from_secs(5)).await;
    assert!(seen.contains("from instance A"), "{seen}");
    eprintln!("cross-instance comment latency: {:?}", started.elapsed());

    // Renames reach B too, and deletion ends B's stream with a notice.
    let id = v["id"].as_str().unwrap().to_string();
    a.api(
        "PATCH",
        &format!("/v1/videos/{id}"),
        Some(&token),
        Some(json!({"title": "Renamed on A"})),
    )
    .await;
    let seen = read_until(&mut body, "Renamed on A", Duration::from_secs(5)).await;
    assert!(seen.contains("Renamed on A"), "{seen}");
    a.api("DELETE", &format!("/v1/videos/{id}"), Some(&token), None)
        .await;
    let seen = read_until(&mut body, "no longer available", Duration::from_secs(5)).await;
    assert!(seen.contains("no longer available"), "{seen}");
    a.t.finish().await;
}

#[tokio::test]
async fn landing_assets_and_mounted_api() {
    let app = App::new().await;
    let r = app.get("/", None).await;
    assert_eq!(r.status, StatusCode::OK);
    assert!(r.body.contains("Download for Mac"));
    assert!(
        r.header("content-security-policy")
            .contains("frame-ancestors 'none'")
    );
    assert!(r.body.contains("/static/datastar-rocket-1.0.4.js"));
    let js = app.get("/static/datastar-rocket-1.0.4.js", None).await;
    assert_eq!(js.status, StatusCode::OK);
    assert!(js.header("cache-control").contains("immutable"));
    assert!(js.body.starts_with("// Datastar v1.0.4 + Rocket beta.2"));
    assert_eq!(app.get("/healthz", None).await.status, StatusCode::OK);
    assert_eq!(
        app.get("/v1/me", None).await.status,
        StatusCode::UNAUTHORIZED
    );
    assert_eq!(
        app.get("/v/nope123", None).await.status,
        StatusCode::NOT_FOUND
    );
    app.t.finish().await;
}

#[tokio::test]
async fn instant_link_upload_and_watch() {
    let app = App::new().await;
    let token = app.user("owner@example.com").await;
    let v = app
        .api(
            "POST",
            "/v1/videos",
            Some(&token),
            Some(json!({"title": "Demo"})),
        )
        .await;
    assert_eq!(v.status, StatusCode::CREATED);
    let v = v.json();
    let slug = slug_of(&v);
    assert_eq!(v["share_url"], format!("http://localhost:8080/v/{slug}"));
    assert_eq!(v["status"], "pending");
    assert_eq!(v["upload"]["min_part_bytes"], 5 * 1024 * 1024);
    assert_eq!(app.store.open_uploads(), 1);

    // The link works before the upload finishes.
    let page = app.get(&format!("/v/{slug}"), None).await;
    assert_eq!(page.status, StatusCode::OK);
    assert!(page.body.contains("Still uploading"));
    assert_eq!(
        app.get(&format!("/v/{slug}/media"), None).await.status,
        StatusCode::NOT_FOUND
    );

    let id = v["id"].as_str().unwrap();
    let bad = app
        .api(
            "POST",
            &format!("/v1/videos/{id}/parts"),
            Some(&token),
            Some(json!({"part_numbers": [0]})),
        )
        .await;
    assert_eq!(bad.status, StatusCode::BAD_REQUEST);
    let parts = app
        .api(
            "POST",
            &format!("/v1/videos/{id}/parts"),
            Some(&token),
            Some(json!({"part_numbers": [1]})),
        )
        .await
        .json();
    let up = upload_id(parts["parts"][0]["url"].as_str().unwrap());
    let e1 = app.store.put_part(&up, 1, 7_000_000);
    let bad = app
        .api(
            "POST",
            &format!("/v1/videos/{id}/complete"),
            Some(&token),
            Some(json!({"parts": [{"part_number": 1, "etag": "\"wrong\""}]})),
        )
        .await;
    assert_eq!(bad.status, StatusCode::BAD_REQUEST, "{}", bad.body);
    let done = app
        .api(
            "POST",
            &format!("/v1/videos/{id}/complete"),
            Some(&token),
            Some(json!({"parts": [{"part_number": 1, "etag": e1}], "duration_ms": 90_000})),
        )
        .await;
    assert_eq!(done.status, StatusCode::OK, "{}", done.body);
    assert_eq!(done.json()["byte_size"], 7_000_000);
    assert_eq!(done.json()["status"], "ready");
    assert_eq!(app.store.open_uploads(), 0);

    // Transcript and poster upload targets.
    let t = app
        .api(
            "POST",
            &format!("/v1/videos/{id}/transcript"),
            Some(&token),
            Some(json!({"byte_size": 60})),
        )
        .await;
    assert_eq!(t.status, StatusCode::OK);
    assert!(
        t.json()["upload"]["url"]
            .as_str()
            .unwrap()
            .ends_with(".vtt?len=60&ttl=600")
    );
    let key = app
        .t
        .owner
        .query_one(
            "SELECT transcript_key FROM videos WHERE id = $1",
            &vals![id],
        )
        .await
        .unwrap()
        .text(0)
        .unwrap();
    app.store.put_bytes(
        &key,
        b"WEBVTT\n\n00:00.000 --> 00:02.000\nHello\n",
        "text/vtt",
    );
    let big = app
        .api(
            "POST",
            &format!("/v1/videos/{id}/thumbnail"),
            Some(&token),
            Some(json!({"byte_size": 3_000_000})),
        )
        .await;
    assert_eq!(big.status, StatusCode::PAYLOAD_TOO_LARGE);

    let page = app.get(&format!("/v/{slug}"), None).await;
    assert!(page.body.contains("<easyshot-player"), "{}", page.body);
    assert!(page.body.contains(&format!("/v/{slug}/transcript.vtt")));
    assert!(page.body.contains("og:title"));
    let media = app.get(&format!("/v/{slug}/media"), None).await;
    assert_eq!(media.status, StatusCode::FOUND);
    assert!(
        media
            .header("location")
            .starts_with("https://store.test/get/v/")
    );
    let vtt = app.get(&format!("/v/{slug}/transcript.vtt"), None).await;
    assert!(vtt.body.starts_with("WEBVTT"));
    assert!(vtt.header("content-type").starts_with("text/vtt"));
    let dl = app.get(&format!("/v/{slug}/download"), None).await;
    assert!(dl.header("location").contains("disposition=attachment"));

    let o = app
        .get(
            &format!("/oembed?url=http%3A%2F%2Flocalhost%3A8080%2Fv%2F{slug}"),
            None,
        )
        .await;
    assert_eq!(o.status, StatusCode::OK, "{}", o.body);
    assert_eq!(o.json()["type"], "video");
    assert!(
        o.json()["html"]
            .as_str()
            .unwrap()
            .contains(&format!("/v/{slug}/embed"))
    );
    let embed = app.get(&format!("/v/{slug}/embed"), None).await;
    assert!(
        embed
            .header("content-security-policy")
            .contains("frame-ancestors *")
    );

    // Views: once per viewer per day, owner excluded.
    app.get(&format!("/v/{slug}"), None).await;
    let n = app
        .t
        .owner
        .query_one("SELECT count(*) FROM item_views", &[])
        .await
        .unwrap()
        .i64(0)
        .unwrap();
    assert_eq!(n, 1);

    // Another user cannot see or touch it through the API.
    let other = app.user("other@example.com").await;
    for (m, p) in [
        ("GET", format!("/v1/videos/{id}")),
        ("DELETE", format!("/v1/videos/{id}")),
    ] {
        assert_eq!(
            app.api(m, &p, Some(&other), None).await.status,
            StatusCode::NOT_FOUND
        );
    }
    let listed = app
        .api("GET", "/v1/videos", Some(&other), None)
        .await
        .json();
    assert_eq!(listed["items"], json!([]));

    // The owner deletes: objects and conversation go too.
    let gone = app
        .api("DELETE", &format!("/v1/videos/{id}"), Some(&token), None)
        .await;
    assert_eq!(gone.status, StatusCode::NO_CONTENT);
    assert!(!app.store.contains(&key));
    assert_eq!(
        app.get(&format!("/v/{slug}"), None).await.status,
        StatusCode::NOT_FOUND
    );
    let n = app
        .t
        .owner
        .query_one("SELECT count(*) FROM item_views", &[])
        .await
        .unwrap()
        .i64(0)
        .unwrap();
    assert_eq!(n, 0);
    app.t.finish().await;
}

#[tokio::test]
async fn comments_reactions_and_live_stream() {
    let app = App::new().await;
    let token = app.user("owner@example.com").await;
    let v = app.ready_video(&token, "Talk").await;
    let slug = slug_of(&v);

    // Open a live stream like a second viewer and read its first event later.
    let live = app
        .router
        .handle(
            http::Request::builder()
                .uri(format!("/v/{slug}/live?since=0"))
                .header("datastar-request", "true")
                .body(Body::empty())
                .unwrap(),
        )
        .await;
    assert_eq!(live.status(), StatusCode::OK);
    assert!(
        live.headers()["content-type"]
            .to_str()
            .unwrap()
            .starts_with("text/event-stream")
    );
    let mut live_body = live.into_body();

    let path = format!("/v/{slug}/comments");
    let r = app
        .form(
            &path,
            &[
                ("body", "<b>bold</b> idea"),
                ("name", "Ann"),
                ("at_time", "1"),
                ("timestamp_ms", "12500"),
            ],
            None,
            true,
        )
        .await;
    assert_eq!(r.status, StatusCode::OK, "{}", r.body);
    assert!(r.header("content-type").starts_with("text/event-stream"));
    assert!(r.body.contains("datastar-patch-elements"));
    assert!(
        r.body.contains("&lt;b&gt;bold&lt;/b&gt; idea"),
        "comment is escaped: {}",
        r.body
    );
    assert!(r.body.contains("data-seek-ms=\"12500\""));
    let plain = app
        .form(&path, &[("body", "plain form")], None, false)
        .await;
    assert_eq!(plain.status, StatusCode::SEE_OTHER);
    let empty = app.form(&path, &[("body", "   ")], None, true).await;
    assert!(empty.body.contains("write a comment first"));
    let rows = app
        .t
        .owner
        .query(
            "SELECT author_name, user_id, timestamp_ms FROM item_comments ORDER BY created_at",
            &[],
        )
        .await
        .unwrap();
    assert_eq!(rows.len(), 2);
    assert_eq!(rows[0].text(0).unwrap(), "Ann");
    assert_eq!(rows[0].opt_text(1).unwrap(), None);
    assert_eq!(rows[0].i64(2).unwrap(), 12500);
    assert_eq!(rows[1].opt_i64(2).unwrap(), None);

    // Guests cannot pass as members: member comments come from the session only.
    let page = app.get(&format!("/v/{slug}"), None).await;
    assert!(page.body.contains("pill guest"));

    let rx = app
        .form(
            &format!("/v/{slug}/reactions"),
            &[("emoji", "🔥"), ("timestamp_ms", "3000")],
            None,
            true,
        )
        .await;
    assert_eq!(rx.status, StatusCode::OK);
    assert!(rx.body.contains("class=\"count\">1<"), "{}", rx.body);
    let bad = app
        .form(
            &format!("/v/{slug}/reactions"),
            &[("emoji", "💩")],
            None,
            true,
        )
        .await;
    assert_eq!(bad.status, StatusCode::BAD_REQUEST);

    // The open stream received the comment.
    let mut seen = String::new();
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    while !seen.contains("bold") && tokio::time::Instant::now() < deadline {
        match tokio::time::timeout(Duration::from_secs(5), live_body.frame()).await {
            Ok(Some(Ok(f))) => {
                if let Some(d) = f.data_ref() {
                    seen.push_str(&String::from_utf8_lossy(d));
                }
            }
            _ => break,
        }
    }
    assert!(seen.contains("event: datastar-patch-elements"), "{seen}");
    assert!(seen.contains("bold"), "{seen}");

    // Cross-site browser posts are refused before any handler runs.
    let csrf = app
        .send(
            http::Request::builder()
                .method("POST")
                .uri(&path)
                .header("content-type", "application/x-www-form-urlencoded")
                .header("origin", "https://evil.example")
                .header("sec-fetch-site", "cross-site")
                .body(Body::from("body=x"))
                .unwrap(),
        )
        .await;
    assert_eq!(csrf.status, StatusCode::FORBIDDEN);
    app.t.finish().await;
}

#[tokio::test]
async fn password_and_private_visibility() {
    let app = App::new().await;
    let token = app.user("owner@example.com").await;
    let v = app.ready_video(&token, "Secret").await;
    let (id, slug) = (v["id"].as_str().unwrap().to_string(), slug_of(&v));

    let r = app
        .api(
            "PATCH",
            &format!("/v1/videos/{id}"),
            Some(&token),
            Some(json!({"visibility": "password"})),
        )
        .await;
    assert_eq!(r.status, StatusCode::BAD_REQUEST, "password required");
    let r = app
        .api(
            "PATCH",
            &format!("/v1/videos/{id}"),
            Some(&token),
            Some(json!({"visibility": "password", "password": "hunter22", "title": "  Secret  plan "})),
        )
        .await;
    assert_eq!(r.json()["title"], "Secret plan");
    let gate = app.get(&format!("/v/{slug}"), None).await;
    assert!(gate.body.contains("password protected"));
    assert!(!gate.body.contains("<easyshot-player"));
    assert!(!gate.body.contains("og:image"));
    assert_eq!(
        app.get(&format!("/v/{slug}/media"), None).await.status,
        StatusCode::NOT_FOUND
    );
    assert_eq!(
        app.get(
            &format!("/oembed?url=http%3A%2F%2Flocalhost%3A8080%2Fv%2F{slug}"),
            None
        )
        .await
        .status,
        StatusCode::NOT_FOUND
    );
    let wrong = app
        .form(
            &format!("/v/{slug}/unlock"),
            &[("password", "nope")],
            None,
            false,
        )
        .await;
    assert_eq!(wrong.status, StatusCode::UNPROCESSABLE_ENTITY);
    let ok = app
        .form(
            &format!("/v/{slug}/unlock"),
            &[("password", "hunter22")],
            None,
            false,
        )
        .await;
    assert_eq!(ok.status, StatusCode::SEE_OTHER);
    let cookie = ok.cookie("sgu_").expect("unlock cookie");
    assert!(cookie.starts_with("__Host-sgu_"));
    let page = app.get(&format!("/v/{slug}"), Some(&cookie)).await;
    assert!(page.body.contains("<easyshot-player"));
    assert_eq!(
        app.get(&format!("/v/{slug}/media"), Some(&cookie))
            .await
            .status,
        StatusCode::FOUND
    );

    // Changing the password revokes earlier unlocks.
    app.api(
        "PATCH",
        &format!("/v1/videos/{id}"),
        Some(&token),
        Some(json!({"visibility": "password", "password": "another1"})),
    )
    .await;
    let page = app.get(&format!("/v/{slug}"), Some(&cookie)).await;
    assert!(page.body.contains("password protected"));

    app.api(
        "PATCH",
        &format!("/v1/videos/{id}"),
        Some(&token),
        Some(json!({"visibility": "private"})),
    )
    .await;
    assert_eq!(
        app.get(&format!("/v/{slug}"), Some(&cookie)).await.status,
        StatusCode::NOT_FOUND
    );
    assert_eq!(
        app.form(
            &format!("/v/{slug}/comments"),
            &[("body", "hi")],
            None,
            false
        )
        .await
        .status,
        StatusCode::NOT_FOUND
    );

    // The owner, signed in on the web, still watches.
    let session = app.web_login("owner@example.com").await;
    let page = app.get(&format!("/v/{slug}"), Some(&session)).await;
    assert_eq!(page.status, StatusCode::OK);
    assert!(page.body.contains("<easyshot-player"));
    app.t.finish().await;
}

#[tokio::test]
async fn sign_in_library_and_owner_actions() {
    let app = App::new().await;
    let token = app.user("owner@example.com").await;
    let v = app.ready_video(&token, "Weekly update").await;
    let id = v["id"].as_str().unwrap().to_string();

    let r = app.get("/library", None).await;
    assert_eq!(r.status, StatusCode::TEMPORARY_REDIRECT);
    assert_eq!(r.header("location"), "/login?next=/library");

    // Unknown emails get the same answer and no mail.
    let r = app
        .form("/login", &[("email", "nobody@example.com")], None, false)
        .await;
    assert!(r.body.contains("name=\"code\""));
    let bad = app
        .form(
            "/login/verify",
            &[("email", "owner@example.com"), ("code", "000000")],
            None,
            false,
        )
        .await;
    assert_eq!(bad.status, StatusCode::UNPROCESSABLE_ENTITY);

    let session = app.web_login("owner@example.com").await;
    assert!(session.starts_with("__Host-sg_session="));
    let lib = app.get("/library", Some(&session)).await;
    assert_eq!(lib.status, StatusCode::OK);
    assert!(lib.body.contains("Weekly update"));
    assert!(lib.body.contains(&format!("id=\"item-{id}\"")));

    let renamed = app
        .form(
            &format!("/library/{id}/rename"),
            &[("title", "Weekly update v2")],
            Some(&session),
            true,
        )
        .await;
    assert!(renamed.body.contains("Weekly update v2") && renamed.body.contains("Renamed."));
    let sent = app
        .form(
            &format!("/library/{id}/send"),
            &[("to", "teammate@example.com")],
            Some(&session),
            true,
        )
        .await;
    assert!(
        sent.body.contains("Sent to teammate@example.com."),
        "{}",
        sent.body
    );
    let mail = app
        .mail
        .sent()
        .into_iter()
        .find(|m| m.to == "teammate@example.com")
        .unwrap();
    assert!(mail.text.contains("/v/") && mail.subject.contains("Weekly update v2"));

    // Someone else's session cannot manage it.
    app.user("intruder@example.com").await;
    let intruder = app.web_login("intruder@example.com").await;
    let r = app
        .form(&format!("/library/{id}/delete"), &[], Some(&intruder), true)
        .await;
    assert_eq!(r.status, StatusCode::NOT_FOUND);

    let del = app
        .form(&format!("/library/{id}/delete"), &[], Some(&session), true)
        .await;
    assert!(del.body.contains(&format!("#item-{id}")), "{}", del.body);
    let lib = app.get("/library", Some(&session)).await;
    assert!(lib.body.contains("No recordings yet"));

    let out = app.form("/logout", &[], Some(&session), false).await;
    assert_eq!(out.status, StatusCode::SEE_OTHER);
    assert_eq!(
        app.get("/library", Some(&session)).await.status,
        StatusCode::TEMPORARY_REDIRECT
    );
    app.t.finish().await;
}

#[tokio::test]
async fn expire_job_purges_expired_and_abandoned_videos() {
    let app = App::new().await;
    let token = app.user("owner@example.com").await;
    let ready = app.ready_video(&token, "Old").await;
    let pending = app
        .api("POST", "/v1/videos", Some(&token), Some(json!({})))
        .await
        .json();
    let keep = app.ready_video(&token, "Keep").await;
    app.t
        .owner
        .execute(
            "UPDATE videos SET expires_at = 1 WHERE id = $1",
            &vals![ready["id"].as_str().unwrap()],
        )
        .await
        .unwrap();
    app.t
        .owner
        .execute(
            "UPDATE videos SET created_at = 1 WHERE id = $1",
            &vals![pending["id"].as_str().unwrap()],
        )
        .await
        .unwrap();
    let r = app
        .api("POST", "/v1/internal/expire", Some("cron-secret"), None)
        .await;
    assert_eq!(r.status, StatusCode::OK, "{}", r.body);
    assert_eq!(r.json()["expired_videos"], 1);
    assert_eq!(r.json()["aborted_uploads"], 1);
    assert_eq!(app.store.open_uploads(), 0);
    let left = app
        .t
        .owner
        .query("SELECT id FROM videos", &[])
        .await
        .unwrap();
    assert_eq!(left.len(), 1);
    assert_eq!(left[0].text(0).unwrap(), keep["id"].as_str().unwrap());
    app.t.finish().await;
}
