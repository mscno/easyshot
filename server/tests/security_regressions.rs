#![allow(dead_code)]
// The public router (Topcoat host + mounted axum API) end to end, against PostgreSQL as the
// app role and the in-memory object store: video upload API, watch page, comments,
// reactions, privacy, live updates, oEmbed, email-code sign-in and the library.

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
        let mut r = http::Request::builder()
            .method(method)
            .uri(path)
            .header("x-forwarded-for", "198.51.100.40");
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

    /// Register (202, no session), then confirm with the mailed code; returns the session
    /// token of the verified account.
    async fn user(&self, email: &str) -> String {
        let r = self
            .api(
                "POST",
                "/v1/auth/register",
                None,
                Some(json!({"email": email, "password": "supersecret123"})),
            )
            .await;
        assert_eq!(r.status, StatusCode::ACCEPTED, "{}", r.body);
        let code = self.mailed_code(email, "Confirm").await;
        let r = self
            .api(
                "POST",
                "/v1/auth/otp/verify",
                None,
                Some(json!({"email": email, "code": code})),
            )
            .await;
        assert_eq!(r.status, StatusCode::OK, "{}", r.body);
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
                Some(json!({"parts": [
                    {"part_number": 1, "size": 5 * 1024 * 1024},
                    {"part_number": 2, "size": 1000}
                ]})),
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
                "/login/code",
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
                "/verify",
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
        self.mailed_code(email, "sign-in code").await
    }

    /// The latest 6-digit code mailed to `email` with `subject` in its subject line.
    async fn mailed_code(&self, email: &str, subject: &str) -> String {
        for _ in 0..50 {
            if let Some(m) = self
                .mail
                .sent()
                .into_iter()
                .rev()
                .find(|m| m.to == email && m.subject.contains(subject))
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
async fn email_owner_must_not_inherit_attacker_credentials() {
    let app = App::new().await;
    let email = "victim@example.test";
    // The attacker reserves the address. With mail on that yields no session, and neither
    // does the attacker's password until the mailbox is proven, so there is nothing to
    // mint an API token with.
    let reg = app
        .api(
            "POST",
            "/v1/auth/register",
            None,
            Some(json!({"email": email, "password": "supersecret123"})),
        )
        .await;
    assert_eq!(
        (reg.status, reg.json()),
        (StatusCode::ACCEPTED, json!({"verification_required": true}))
    );
    let attacker_login = app
        .api(
            "POST",
            "/v1/auth/login",
            None,
            Some(json!({"email": email, "password": "supersecret123"})),
        )
        .await;
    assert_eq!(attacker_login.status, StatusCode::FORBIDDEN);
    assert_eq!(attacker_login.json()["error"]["code"], "EMAIL_NOT_VERIFIED");
    assert!(attacker_login.json().get("token").is_none());
    let token = app
        .api(
            "POST",
            "/v1/tokens",
            None,
            Some(json!({"name": "pre-verification token"})),
        )
        .await;
    assert_eq!(token.status, StatusCode::UNAUTHORIZED);

    // The real mailbox owner signs up with a different password (after the resend
    // cooldown the attacker's codes started), then confirms with the code mailed for it.
    // (Codes are issued in the background: let the attacker's settle first.)
    tokio::time::sleep(Duration::from_millis(300)).await;
    app.t
        .owner
        .execute("UPDATE auth_codes SET created_at = created_at - 60000", &[])
        .await
        .unwrap();
    app.mail.clear();
    let signup = app
        .form(
            "/signup",
            &[("email", email), ("password", "victim-new-password")],
            None,
            false,
        )
        .await;
    assert_eq!(signup.status, StatusCode::OK);
    let code = app.mailed_code(email, "Confirm").await;
    let verify = app
        .form("/verify", &[("email", email), ("code", &code)], None, false)
        .await;
    assert_eq!(verify.status, StatusCode::SEE_OTHER);
    let victim = verify.cookie("sg_session").expect("victim session");
    let old_password = app
        .api(
            "POST",
            "/v1/auth/login",
            None,
            Some(json!({"email":email,"password":"supersecret123"})),
        )
        .await
        .status;
    let new_password = app
        .api(
            "POST",
            "/v1/auth/login",
            None,
            Some(json!({"email":email,"password":"victim-new-password"})),
        )
        .await
        .status;
    // A reset afterwards keeps the account the victim's.
    app.form("/forgot", &[("email", email)], None, false).await;
    let code = app.mailed_code(email, "Reset").await;
    let reset = app
        .form(
            "/reset",
            &[
                ("email", email),
                ("code", &code),
                ("password", "victim-reset-password"),
            ],
            None,
            false,
        )
        .await;
    assert_eq!(reset.status, StatusCode::SEE_OTHER);
    let old_password_after_reset = app
        .api(
            "POST",
            "/v1/auth/login",
            None,
            Some(json!({"email":email,"password":"supersecret123"})),
        )
        .await
        .status;
    let victim_page = app.get("/account", Some(&victim)).await.status;
    app.t.finish().await;
    assert_eq!(
        (
            old_password,
            new_password,
            old_password_after_reset,
            victim_page
        ),
        (
            StatusCode::UNAUTHORIZED,
            StatusCode::OK,
            StatusCode::UNAUTHORIZED,
            StatusCode::TEMPORARY_REDIRECT
        ),
        "attacker password after victim verification, victim password, attacker password \
         after reset, victim's pre-reset session after reset"
    );
}

#[tokio::test]
async fn password_reset_revokes_api_tokens() {
    let app = App::new().await;
    let email = "owner@example.test";
    let session = app.user(email).await;
    let created = app
        .api(
            "POST",
            "/v1/tokens",
            Some(&session),
            Some(json!({"name": "agent"})),
        )
        .await;
    assert_eq!(created.status, StatusCode::CREATED, "{}", created.body);
    let pat = created.json()["token"].as_str().unwrap().to_string();
    assert_eq!(
        app.api("GET", "/v1/me", Some(&pat), None).await.status,
        StatusCode::OK
    );
    app.form("/forgot", &[("email", email)], None, false).await;
    let code = app.mailed_code(email, "Reset").await;
    let reset = app
        .form(
            "/reset",
            &[
                ("email", email),
                ("code", &code),
                ("password", "a brand new password"),
            ],
            None,
            false,
        )
        .await;
    assert_eq!(reset.status, StatusCode::SEE_OTHER);
    let pat_after = app.api("GET", "/v1/me", Some(&pat), None).await.status;
    let session_after = app.api("GET", "/v1/me", Some(&session), None).await.status;
    let tokens = app
        .t
        .owner
        .query_one(
            "SELECT count(*) FROM api_tokens WHERE revoked_at IS NULL",
            &[],
        )
        .await
        .unwrap()
        .i64(0)
        .unwrap();
    let verified = app
        .t
        .owner
        .query_one("SELECT email_verified_at FROM users", &[])
        .await
        .unwrap()
        .opt_i64(0)
        .unwrap();
    app.t.finish().await;
    assert_eq!(
        (pat_after, session_after, tokens),
        (StatusCode::UNAUTHORIZED, StatusCode::UNAUTHORIZED, 0)
    );
    assert!(verified.is_some());
}

#[tokio::test]
async fn review_complete_recovers_after_storage_commit_before_database_commit() {
    use easyshot_server::storage::ObjectStore;
    let app = App::new().await;
    let token = app.user("owner@example.test").await;
    let created = app
        .api("POST", "/v1/videos", Some(&token), Some(json!({})))
        .await
        .json();
    let id = created["id"].as_str().unwrap();
    let row = app
        .t
        .owner
        .query_one(
            "SELECT object_key, upload_id FROM videos WHERE id=$1",
            &vals![id],
        )
        .await
        .unwrap();
    let key = row.text(0).unwrap();
    let upload = row.text(1).unwrap();
    let presigned = app.api("POST", &format!("/v1/videos/{id}/parts"), Some(&token),
        Some(json!({"parts":[{"part_number":1,"size":1000}]}))).await;
    assert_eq!(presigned.status, StatusCode::OK, "{}", presigned.body);
    let tag = app.store.put_part(&upload, 1, 1000);
    // Simulate the exact durable state after S3 commits and the process/DB fails
    // before videos.status becomes ready. No live storage service is contacted.
    app.store
        .complete_multipart(&key, &upload, &[(1, tag.clone())])
        .await
        .unwrap();
    let retry = app
        .api(
            "POST",
            &format!("/v1/videos/{id}/complete"),
            Some(&token),
            Some(json!({"parts":[{"part_number":1,"etag":tag}]})),
        )
        .await;
    let durable = app
        .t
        .owner
        .query_one("SELECT status FROM videos WHERE id=$1", &vals![id])
        .await
        .unwrap()
        .text(0)
        .unwrap();
    app.t.finish().await;
    assert_eq!(
        (retry.status, durable),
        (StatusCode::OK, "ready".to_string()),
        "{}",
        retry.body
    );
}

#[tokio::test]
async fn concurrent_code_requests_obey_resend_cooldown() {
    let app = App::new().await;
    let email = "codes@example.test";
    app.user(email).await;
    app.mailed_code(email, "Confirm").await;
    let calls = (0..24).map(|_| {
        app.api(
            "POST",
            "/v1/auth/otp/request",
            None,
            Some(json!({"email":email})),
        )
    });
    futures_util::future::join_all(calls).await;
    tokio::time::sleep(Duration::from_secs(1)).await;
    let sent = app
        .mail
        .sent()
        .iter()
        .filter(|m| m.subject.contains("sign-in code"))
        .count();
    app.t.finish().await;
    assert!(
        sent <= 1,
        "24 concurrent requests sent {sent} sign-in emails inside one second"
    );
}

#[tokio::test]
async fn review_advertised_five_gib_upload_fits_completion_body_limit() {
    let app = App::new().await;
    let token = app.user("large@example.test").await;
    let created = app
        .api("POST", "/v1/videos", Some(&token), Some(json!({})))
        .await
        .json();
    assert_eq!(created["upload"]["max_bytes"], 5_i64 * 1024 * 1024 * 1024);
    let id = created["id"].as_str().unwrap();
    let parts: Vec<Value> = (1..=1024)
        .map(|i| json!({"part_number":i,"etag":format!("\"{}\"","a".repeat(32))}))
        .collect();
    let body = json!({"parts":parts,"duration_ms":3600000,"width":1920,"height":1080});
    let size = body.to_string().len();
    let res = app
        .api(
            "POST",
            &format!("/v1/videos/{id}/complete"),
            Some(&token),
            Some(body),
        )
        .await;
    app.t.finish().await;
    assert_ne!(
        res.status,
        StatusCode::PAYLOAD_TOO_LARGE,
        "{size}-byte completion body rejected before storage validation: {}",
        res.body
    );
}

#[tokio::test]
async fn api_login_obeys_per_address_limit() {
    let app = App::new().await;
    let mut statuses = Vec::new();
    for i in 0..21 {
        let res=app.api("POST","/v1/auth/login",None,
            Some(json!({"email":format!("unknown-{i}@example.test"),"password":"wrong-password"}))).await;
        statuses.push(res.status);
    }
    app.t.finish().await;
    assert_eq!(
        statuses.last(),
        Some(&StatusCode::TOO_MANY_REQUESTS),
        "21 logins from the same address: {statuses:?}"
    );
}
