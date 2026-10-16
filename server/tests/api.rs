//! Integration tests against PostgreSQL (`TEST_DATABASE_URL`, one throwaway schema per
//! test). The app runs as the `easyshot_app` role, so row-level security applies.

use std::sync::Arc;

use axum::Router;
use axum::body::Body;
use axum::http::{HeaderMap, Method, Request, StatusCode, header};
use easyshot_server::config::Config;
use easyshot_server::db::{Db, DbError};
use easyshot_server::mailer::{Email, LettermintMailer, Mailer, MemoryMailer};
use easyshot_server::repo::{self, now_ms};
use easyshot_server::storage::MemoryStore;
use easyshot_server::{AppState, router, vals};
use http_body_util::BodyExt;
use serde_json::{Value, json};
use tower::ServiceExt;

const HOUR: i64 = 3_600_000;
const DAY: i64 = 24 * HOUR;

mod common;

struct Ctx {
    app: Router,
    /// Owner handle for setup and inspection (bypasses RLS); the app uses the app role.
    db: Db,
    store: Arc<MemoryStore>,
    mail: Arc<MemoryMailer>,
    cfg: Config,
    test_db: common::TestDb,
}

impl Ctx {
    async fn postgres() -> Ctx {
        let test_db = common::database().await;
        let cfg = test_db.config();
        let store = Arc::new(MemoryStore::new());
        let mail = MemoryMailer::new();
        let app = router(
            AppState::new(test_db.app.clone(), store.clone(), cfg.clone())
                .with_mailer(mail.clone()),
        );
        Ctx {
            app,
            db: test_db.owner.clone(),
            store,
            mail,
            cfg,
            test_db,
        }
    }

    /// Same database and store, different configuration.
    fn reconfigure(mut self, f: impl FnOnce(&mut Config)) -> Ctx {
        f(&mut self.cfg);
        self.app = router(
            AppState::new(
                self.test_db.app.clone(),
                self.store.clone(),
                self.cfg.clone(),
            )
            .with_mailer(self.mail.clone()),
        );
        self
    }

    async fn call(
        &self,
        method: Method,
        path: &str,
        token: Option<&str>,
        body: Option<Value>,
    ) -> (StatusCode, HeaderMap, Value) {
        self.call_via(&self.app, method, path, token, body).await
    }

    async fn call_via(
        &self,
        app: &Router,
        method: Method,
        path: &str,
        token: Option<&str>,
        body: Option<Value>,
    ) -> (StatusCode, HeaderMap, Value) {
        let mut req = Request::builder().method(method).uri(path);
        if let Some(t) = token {
            req = req.header(header::AUTHORIZATION, format!("Bearer {t}"));
        }
        let body = match body {
            Some(b) => {
                req = req.header(header::CONTENT_TYPE, "application/json");
                Body::from(b.to_string())
            }
            None => Body::empty(),
        };
        let res = app.clone().oneshot(req.body(body).unwrap()).await.unwrap();
        let (parts, body) = res.into_parts();
        let bytes = body.collect().await.unwrap().to_bytes();
        let v = serde_json::from_slice(&bytes).unwrap_or(Value::Null);
        (parts.status, parts.headers, v)
    }

    /// Register (202, no session) and confirm with the mailed code through `otp/verify`;
    /// returns the session token of the now verified account.
    async fn register(&self, email: &str) -> String {
        let (s, _, v) = self
            .call(
                Method::POST,
                "/v1/auth/register",
                None,
                Some(json!({"email": email, "password": "supersecret123", "device_name": "test"})),
            )
            .await;
        assert_eq!(s, StatusCode::ACCEPTED, "{v}");
        assert_eq!(v["verification_required"], true);
        let attempt = v["attempt"].as_str().unwrap().to_owned();
        let to = email.trim().to_lowercase();
        let code = self.next_code(&to).await;
        let (s, v) = self
            .post(
                "/v1/auth/otp/verify",
                None,
                json!({"email": to, "code": code, "device_name": "test", "attempt": attempt}),
            )
            .await;
        assert_eq!(s, StatusCode::OK, "{v}");
        assert_eq!(v["user"]["email_verified"], true);
        v["token"].as_str().unwrap().to_string()
    }

    /// The same app without mail: registration signs straight in, unverified.
    fn without_mail(&self) -> Router {
        router(AppState::new(
            self.test_db.app.clone(),
            self.store.clone(),
            self.cfg.clone(),
        ))
    }

    /// An unverified account holding a session: registered through the app without mail
    /// (the only way to get one), to exercise what such a session may and may not do.
    async fn unverified_session(&self, email: &str, password: &str) -> String {
        let (s, _, v) = self
            .call_via(
                &self.without_mail(),
                Method::POST,
                "/v1/auth/register",
                None,
                Some(json!({"email": email, "password": password})),
            )
            .await;
        assert_eq!(s, StatusCode::CREATED, "{v}");
        assert_eq!(v["user"]["email_verified"], false);
        v["token"].as_str().unwrap().to_string()
    }

    /// create + fake upload + complete. Returns the Screenshot object.
    async fn upload(&self, token: &str, size: i64) -> Value {
        let (s, _, v) = self
            .call(Method::POST, "/v1/screenshots", Some(token), Some(json!({"content_type": "image/png", "byte_size": size, "width": 10, "height": 20, "filename": "a.png"})))
            .await;
        assert_eq!(s, StatusCode::CREATED, "{v}");
        let key = self.key_of(v["id"].as_str().unwrap()).await;
        self.store.put(&key, size, "image/png");
        let (s, _, v) = self
            .call(
                Method::POST,
                &format!("/v1/screenshots/{}/complete", v["id"].as_str().unwrap()),
                Some(token),
                None,
            )
            .await;
        assert_eq!(s, StatusCode::OK, "{v}");
        v
    }

    /// Mail is sent from a background task: wait for the next message to `to`.
    async fn next_mail(&self, to: &str) -> Email {
        for _ in 0..100 {
            if let Some(e) = self.mail.sent().into_iter().rev().find(|e| e.to == to) {
                self.mail.clear();
                return e;
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }
        panic!("no email to {to}");
    }

    async fn next_code(&self, to: &str) -> String {
        let e = self.next_mail(to).await;
        let digits: String = e
            .text
            .split_whitespace()
            .find(|w| w.len() == 6 && w.bytes().all(|b| b.is_ascii_digit()))
            .expect("code in email")
            .into();
        digits
    }

    async fn assert_no_mail(&self) {
        tokio::time::sleep(std::time::Duration::from_millis(250)).await;
        assert!(self.mail.sent().is_empty(), "{:?}", self.mail.sent());
    }

    /// Make the resend cooldown / rate window elapse.
    async fn age_codes(&self, ms: i64) {
        self.db
            .execute(
                "UPDATE auth_codes SET created_at = created_at - $1",
                &vals![ms],
            )
            .await
            .unwrap();
    }

    async fn post(&self, path: &str, token: Option<&str>, body: Value) -> (StatusCode, Value) {
        let (s, _, v) = self.call(Method::POST, path, token, Some(body)).await;
        (s, v)
    }

    async fn key_of(&self, id: &str) -> String {
        self.db
            .query_one(
                "SELECT object_key FROM screenshots WHERE id = $1",
                &vals![id],
            )
            .await
            .unwrap()
            .text(0)
            .unwrap()
    }

    async fn count(&self, table: &str) -> i64 {
        self.db
            .query_one(&format!("SELECT count(*) FROM {table}"), &[])
            .await
            .unwrap()
            .i64(0)
            .unwrap()
    }

    async fn cleanup(self) {
        self.test_db.finish().await;
    }
}

async fn healthz(c: Ctx) {
    let (s, _, v) = c.call(Method::GET, "/healthz?db=1", None, None).await;
    assert_eq!((s, v), (StatusCode::OK, json!({"ok": true})));
    c.cleanup().await;
}

async fn register_login_me(c: Ctx) {
    let t = c.register("  Alice@Example.com ").await;
    assert!(t.starts_with("sgs_"));
    let (s, _, me) = c.call(Method::GET, "/v1/me", Some(&t), None).await;
    assert_eq!(s, StatusCode::OK);
    assert_eq!(me["email"], "alice@example.com");
    assert_eq!(me["plan"], "free");
    assert_eq!(me["retention_days"], 30);
    assert_eq!(me["usage"], json!({"screenshots": 0, "bytes": 0}));

    let (s, _, v) = c
        .call(
            Method::POST,
            "/v1/auth/login",
            None,
            Some(json!({"email": "ALICE@example.com", "password": "supersecret123"})),
        )
        .await;
    assert_eq!(s, StatusCode::OK, "{v}");
    assert!(v["expires_at"].is_string());
    assert_eq!(v["user"]["email"], "alice@example.com");
    let t2 = v["token"].as_str().unwrap();
    let (s, ..) = c.call(Method::GET, "/v1/me", Some(t2), None).await;
    assert_eq!(s, StatusCode::OK);

    // logout kills only that session
    let (s, ..) = c
        .call(Method::POST, "/v1/auth/logout", Some(t2), None)
        .await;
    assert_eq!(s, StatusCode::NO_CONTENT);
    let (s, _, v) = c.call(Method::GET, "/v1/me", Some(t2), None).await;
    assert_eq!(s, StatusCode::UNAUTHORIZED);
    assert_eq!(v["error"]["code"], "UNAUTHORIZED");
    let (s, ..) = c.call(Method::GET, "/v1/me", Some(&t), None).await;
    assert_eq!(s, StatusCode::OK);
    let (s, ..) = c.call(Method::GET, "/v1/me", None, None).await;
    assert_eq!(s, StatusCode::UNAUTHORIZED);
    c.cleanup().await;
}

async fn register_validation_and_duplicates(c: Ctx) {
    c.register("a@example.com").await;
    // A taken (verified) address answers exactly like a new one, mails its owner a sign-in
    // code and keeps the owner's password.
    let (s, _, v) = c
        .call(
            Method::POST,
            "/v1/auth/register",
            None,
            Some(json!({"email": "A@example.com", "password": "another-password"})),
        )
        .await;
    assert_eq!(s, StatusCode::ACCEPTED, "{v}");
    assert_eq!(v["verification_required"], true);
    assert_eq!(v["attempt"].as_str().unwrap().len(), 43);
    assert!(v.get("token").is_none());
    assert!(
        c.next_mail("a@example.com")
            .await
            .subject
            .contains("sign-in code")
    );
    let (s, _) = c
        .post(
            "/v1/auth/login",
            None,
            json!({"email": "a@example.com", "password": "supersecret123"}),
        )
        .await;
    assert_eq!(s, StatusCode::OK);
    let (s, v) = c
        .post(
            "/v1/auth/login",
            None,
            json!({"email": "a@example.com", "password": "another-password"}),
        )
        .await;
    assert_eq!(
        (s, v["error"]["code"].as_str()),
        (StatusCode::UNAUTHORIZED, Some("INVALID_CREDENTIALS"))
    );
    // Without mail there is nothing to verify with: the old answer.
    let (s, _, v) = c
        .call_via(
            &c.without_mail(),
            Method::POST,
            "/v1/auth/register",
            None,
            Some(json!({"email": "A@example.com", "password": "supersecret123"})),
        )
        .await;
    assert_eq!(s, StatusCode::CONFLICT);
    assert_eq!(v["error"]["code"], "EMAIL_TAKEN");
    let (s, ..) = c
        .call(
            Method::POST,
            "/v1/auth/register",
            None,
            Some(json!({"email": "b@example.com", "password": "short"})),
        )
        .await;
    assert_eq!(s, StatusCode::BAD_REQUEST);
    let (s, ..) = c
        .call(
            Method::POST,
            "/v1/auth/register",
            None,
            Some(json!({"email": "nope", "password": "supersecret123"})),
        )
        .await;
    assert_eq!(s, StatusCode::BAD_REQUEST);
    let (s, _, v) = c
        .call(
            Method::POST,
            "/v1/auth/register",
            None,
            Some(json!({"bogus": 1})),
        )
        .await;
    assert_eq!(s, StatusCode::BAD_REQUEST);
    assert_eq!(v["error"]["code"], "INVALID_REQUEST");
    c.cleanup().await;
}

async fn signups_disabled(c: Ctx) {
    let c = c.reconfigure(|c| c.allow_signups = false);
    let (s, _, v) = c
        .call(
            Method::POST,
            "/v1/auth/register",
            None,
            Some(json!({"email": "a@example.com", "password": "supersecret123"})),
        )
        .await;
    assert_eq!(s, StatusCode::FORBIDDEN);
    assert_eq!(v["error"]["code"], "SIGNUPS_DISABLED");
    c.cleanup().await;
}

async fn bad_password_and_throttle(c: Ctx) {
    c.register("a@example.com").await;
    for _ in 0..10 {
        let (s, _, v) = c
            .call(
                Method::POST,
                "/v1/auth/login",
                None,
                Some(json!({"email": "a@example.com", "password": "wrongwrongwrong"})),
            )
            .await;
        assert_eq!(s, StatusCode::UNAUTHORIZED);
        assert_eq!(v["error"]["code"], "INVALID_CREDENTIALS");
    }
    // unknown email gives the same error
    let (s, _, v2) = c
        .call(
            Method::POST,
            "/v1/auth/login",
            None,
            Some(json!({"email": "ghost@example.com", "password": "wrongwrongwrong"})),
        )
        .await;
    assert_eq!(s, StatusCode::UNAUTHORIZED);
    assert_eq!(v2["error"]["message"], "invalid email or password");
    // now throttled even with the right password
    let (s, _, v) = c
        .call(
            Method::POST,
            "/v1/auth/login",
            None,
            Some(json!({"email": "a@example.com", "password": "supersecret123"})),
        )
        .await;
    assert_eq!(s, StatusCode::TOO_MANY_REQUESTS);
    assert_eq!(v["error"]["code"], "RATE_LIMITED");
    c.cleanup().await;
}

async fn screenshot_lifecycle(c: Ctx) {
    let t = c.register("a@example.com").await;

    let (s, _, v) = c
        .call(Method::POST, "/v1/screenshots", Some(&t), Some(json!({"content_type": "image/png", "byte_size": 1234, "width": 10, "height": 20, "filename": "a.png"})))
        .await;
    assert_eq!(s, StatusCode::CREATED, "{v}");
    let id = v["id"].as_str().unwrap().to_string();
    let slug = v["slug"].as_str().unwrap().to_string();
    assert_eq!(slug.len(), 12);
    assert_eq!(
        v["share_url"],
        format!("http://localhost:8080/s/{slug}.png")
    );
    assert_eq!(v["upload"]["method"], "PUT");
    assert_eq!(v["upload"]["headers"]["Content-Type"], "image/png");
    assert!(v["upload"]["url"].as_str().unwrap().contains("ttl=600"));

    // not uploaded yet
    let (s, _, v) = c
        .call(
            Method::POST,
            &format!("/v1/screenshots/{id}/complete"),
            Some(&t),
            None,
        )
        .await;
    assert_eq!(s, StatusCode::CONFLICT);
    assert_eq!(v["error"]["code"], "NOT_UPLOADED");
    // pending: share link 404 and not in list
    let (s, ..) = c.call(Method::GET, &format!("/s/{slug}"), None, None).await;
    assert_eq!(s, StatusCode::NOT_FOUND);
    let (_, _, l) = c.call(Method::GET, "/v1/screenshots", Some(&t), None).await;
    assert_eq!(l["items"].as_array().unwrap().len(), 0);

    // upload + complete (twice: idempotent)
    let key = c.key_of(&id).await;
    assert!(key.starts_with("u/") && key.ends_with(&format!("{id}.png")));
    c.store.put(&key, 1234, "image/png");
    for _ in 0..2 {
        let (s, _, v) = c
            .call(
                Method::POST,
                &format!("/v1/screenshots/{id}/complete"),
                Some(&t),
                None,
            )
            .await;
        assert_eq!(s, StatusCode::OK, "{v}");
        assert_eq!(v["id"], id);
        assert_eq!(v["byte_size"], 1234);
        assert_eq!(v["width"], 10);
        assert_eq!(v["filename"], "a.png");
        assert!(v["image_url"].as_str().unwrap().contains("ttl=3600"));
    }

    let (_, _, l) = c.call(Method::GET, "/v1/screenshots", Some(&t), None).await;
    assert_eq!(l["items"].as_array().unwrap().len(), 1);
    assert_eq!(l["items"][0]["slug"], slug);
    assert!(l["next_cursor"].is_null());
    let (_, _, me) = c.call(Method::GET, "/v1/me", Some(&t), None).await;
    assert_eq!(me["usage"], json!({"screenshots": 1, "bytes": 1234}));

    // public share, with and without ext, GET and HEAD
    for (m, p) in [
        (Method::GET, format!("/s/{slug}")),
        (Method::GET, format!("/s/{slug}.png")),
        (Method::HEAD, format!("/s/{slug}.png")),
        (Method::HEAD, format!("/s/{slug}")),
    ] {
        let (s, h, _) = c.call(m, &p, None, None).await;
        assert_eq!(s, StatusCode::FOUND, "{p}");
        let loc = h[header::LOCATION].to_str().unwrap();
        assert!(
            loc.contains(&key)
                && loc.contains("ttl=300")
                && loc.contains("response-content-disposition=inline"),
            "{loc}"
        );
        assert_eq!(h[header::CACHE_CONTROL], "private, max-age=60");
        assert_eq!(h["x-robots-tag"], "noindex");
        assert_eq!(h[header::REFERRER_POLICY], "no-referrer");
    }
    let (s, h, _) = c.call(Method::GET, "/s/doesnotexist", None, None).await;
    assert_eq!(s, StatusCode::NOT_FOUND);
    assert_eq!(h["x-robots-tag"], "noindex");

    // delete
    let (s, ..) = c
        .call(
            Method::DELETE,
            &format!("/v1/screenshots/{id}"),
            Some(&t),
            None,
        )
        .await;
    assert_eq!(s, StatusCode::NO_CONTENT);
    assert!(!c.store.contains(&key));
    let (s, ..) = c
        .call(
            Method::DELETE,
            &format!("/v1/screenshots/{id}"),
            Some(&t),
            None,
        )
        .await;
    assert_eq!(s, StatusCode::NOT_FOUND);
    let (s, ..) = c.call(Method::GET, &format!("/s/{slug}"), None, None).await;
    assert_eq!(s, StatusCode::NOT_FOUND);
    c.cleanup().await;
}

async fn create_validation(c: Ctx) {
    let t = c.register("a@example.com").await;
    let (s, _, v) = c
        .call(
            Method::POST,
            "/v1/screenshots",
            Some(&t),
            Some(json!({"content_type": "image/png", "byte_size": 26_214_401})),
        )
        .await;
    assert_eq!(s, StatusCode::PAYLOAD_TOO_LARGE);
    assert_eq!(v["error"]["code"], "TOO_LARGE");
    let (s, _, v) = c
        .call(
            Method::POST,
            "/v1/screenshots",
            Some(&t),
            Some(json!({"content_type": "video/mp4", "byte_size": 10})),
        )
        .await;
    assert_eq!(s, StatusCode::UNSUPPORTED_MEDIA_TYPE);
    assert_eq!(v["error"]["code"], "UNSUPPORTED_TYPE");
    let (s, ..) = c
        .call(
            Method::POST,
            "/v1/screenshots",
            None,
            Some(json!({"content_type": "image/png", "byte_size": 10})),
        )
        .await;
    assert_eq!(s, StatusCode::UNAUTHORIZED);
    c.cleanup().await;
}

async fn size_mismatch(c: Ctx) {
    let t = c.register("a@example.com").await;
    let (_, _, v) = c
        .call(
            Method::POST,
            "/v1/screenshots",
            Some(&t),
            Some(json!({"content_type": "image/jpeg", "byte_size": 100})),
        )
        .await;
    let id = v["id"].as_str().unwrap().to_string();
    assert!(v["share_url"].as_str().unwrap().ends_with(".jpg"));
    let key = c.key_of(&id).await;
    c.store.put(&key, 99, "image/jpeg");
    let (s, _, v) = c
        .call(
            Method::POST,
            &format!("/v1/screenshots/{id}/complete"),
            Some(&t),
            None,
        )
        .await;
    assert_eq!(s, StatusCode::UNPROCESSABLE_ENTITY);
    assert_eq!(v["error"]["code"], "SIZE_MISMATCH");
    assert!(!c.store.contains(&key));
    assert_eq!(c.count("screenshots").await, 0);
    c.cleanup().await;
}

async fn cross_user_denied(c: Ctx) {
    let a = c.register("a@example.com").await;
    let b = c.register("b@example.com").await;
    let (_, _, v) = c
        .call(
            Method::POST,
            "/v1/screenshots",
            Some(&a),
            Some(json!({"content_type": "image/png", "byte_size": 5})),
        )
        .await;
    let id = v["id"].as_str().unwrap().to_string();
    let key = c.key_of(&id).await;
    c.store.put(&key, 5, "image/png");
    let (s, ..) = c
        .call(
            Method::POST,
            &format!("/v1/screenshots/{id}/complete"),
            Some(&b),
            None,
        )
        .await;
    assert_eq!(s, StatusCode::NOT_FOUND);
    let (s, ..) = c
        .call(
            Method::POST,
            &format!("/v1/screenshots/{id}/complete"),
            Some(&a),
            None,
        )
        .await;
    assert_eq!(s, StatusCode::OK);
    let (s, ..) = c
        .call(
            Method::DELETE,
            &format!("/v1/screenshots/{id}"),
            Some(&b),
            None,
        )
        .await;
    assert_eq!(s, StatusCode::NOT_FOUND);
    assert!(c.store.contains(&key));
    let (_, _, l) = c.call(Method::GET, "/v1/screenshots", Some(&b), None).await;
    assert_eq!(l["items"].as_array().unwrap().len(), 0);
    let (s, ..) = c
        .call(Method::DELETE, "/v1/screenshots/not-a-uuid", Some(&b), None)
        .await;
    assert_eq!(s, StatusCode::NOT_FOUND);
    c.cleanup().await;
}

async fn pagination(c: Ctx) {
    let t = c.register("a@example.com").await;
    let mut ids = vec![];
    for i in 0..5 {
        tokio::time::sleep(std::time::Duration::from_millis(3)).await; // distinct created_at
        let v = c.upload(&t, 10 + i).await;
        ids.push(v["id"].as_str().unwrap().to_string());
    }
    ids.reverse(); // newest first
    let mut seen = vec![];
    let mut path = "/v1/screenshots?limit=2".to_string();
    let mut pages = 0;
    loop {
        let (s, _, v) = c.call(Method::GET, &path, Some(&t), None).await;
        assert_eq!(s, StatusCode::OK, "{v}");
        pages += 1;
        for it in v["items"].as_array().unwrap() {
            seen.push(it["id"].as_str().unwrap().to_string());
        }
        match v["next_cursor"].as_str() {
            Some(cur) => path = format!("/v1/screenshots?limit=2&before={cur}"),
            None => break,
        }
    }
    assert_eq!(pages, 3);
    assert_eq!(seen, ids);
    let (s, _, v) = c
        .call(
            Method::GET,
            "/v1/screenshots?before=garbage",
            Some(&t),
            None,
        )
        .await;
    assert_eq!(s, StatusCode::BAD_REQUEST, "{v}");
    let (_, _, v) = c
        .call(Method::GET, "/v1/screenshots?limit=0", Some(&t), None)
        .await;
    assert_eq!(v["items"].as_array().unwrap().len(), 1); // clamped to 1
    c.cleanup().await;
}

async fn api_tokens(c: Ctx) {
    let t = c.register("a@example.com").await;
    let (s, _, v) = c
        .call(
            Method::POST,
            "/v1/tokens",
            Some(&t),
            Some(json!({"name": "ci"})),
        )
        .await;
    assert_eq!(s, StatusCode::CREATED, "{v}");
    let pat = v["token"].as_str().unwrap().to_string();
    let id = v["id"].as_str().unwrap().to_string();
    assert!(pat.starts_with("sgp_"));
    let (s, ..) = c.call(Method::GET, "/v1/me", Some(&pat), None).await;
    assert_eq!(s, StatusCode::OK);
    let (_, _, l) = c.call(Method::GET, "/v1/tokens", Some(&pat), None).await;
    assert_eq!(l["items"].as_array().unwrap().len(), 1);
    assert_eq!(l["items"][0]["name"], "ci");
    assert!(l["items"][0].get("token").is_none());
    assert!(l["items"][0]["last_used_at"].is_string());
    // logout with api token is a no-op
    let (s, ..) = c
        .call(Method::POST, "/v1/auth/logout", Some(&pat), None)
        .await;
    assert_eq!(s, StatusCode::NO_CONTENT);
    let (s, ..) = c.call(Method::GET, "/v1/me", Some(&pat), None).await;
    assert_eq!(s, StatusCode::OK);
    // another user cannot revoke
    let b = c.register("b@example.com").await;
    let (s, ..) = c
        .call(Method::DELETE, &format!("/v1/tokens/{id}"), Some(&b), None)
        .await;
    assert_eq!(s, StatusCode::NOT_FOUND);
    let (s, ..) = c
        .call(Method::DELETE, &format!("/v1/tokens/{id}"), Some(&t), None)
        .await;
    assert_eq!(s, StatusCode::NO_CONTENT);
    let (s, ..) = c.call(Method::GET, "/v1/me", Some(&pat), None).await;
    assert_eq!(s, StatusCode::UNAUTHORIZED);
    let (s, ..) = c.call(Method::GET, "/v1/me", Some("sgp_bogus"), None).await;
    assert_eq!(s, StatusCode::UNAUTHORIZED);
    let (s, ..) = c
        .call(Method::GET, "/v1/me", Some("other_token"), None)
        .await;
    assert_eq!(s, StatusCode::UNAUTHORIZED);
    // An unverified account (here a session made while mail was off) gets no token.
    let u = c
        .unverified_session("u@example.com", "supersecret123")
        .await;
    let (s, v) = c.post("/v1/tokens", Some(&u), json!({"name": "ci"})).await;
    assert_eq!(
        (s, v["error"]["code"].as_str()),
        (StatusCode::FORBIDDEN, Some("EMAIL_NOT_VERIFIED"))
    );
    c.cleanup().await;
}

async fn disabled_user_rejected(c: Ctx) {
    let t = c.register("a@example.com").await;
    c.db.execute("UPDATE users SET disabled_at = $1", &vals![now_ms()])
        .await
        .unwrap();
    let (s, ..) = c.call(Method::GET, "/v1/me", Some(&t), None).await;
    assert_eq!(s, StatusCode::UNAUTHORIZED);
    let (s, ..) = c
        .call(
            Method::POST,
            "/v1/auth/login",
            None,
            Some(json!({"email": "a@example.com", "password": "supersecret123"})),
        )
        .await;
    assert_eq!(s, StatusCode::UNAUTHORIZED);
    c.cleanup().await;
}

async fn session_sliding_expiry(c: Ctx) {
    let t = c.register("a@example.com").await;
    let now = now_ms();
    c.db.execute(
        "UPDATE sessions SET last_used_at = $1, expires_at = $2",
        &vals![now - 2 * HOUR, now + 5 * DAY],
    )
    .await
    .unwrap();
    c.call(Method::GET, "/v1/me", Some(&t), None).await;
    let exp =
        c.db.query_one("SELECT expires_at FROM sessions", &[])
            .await
            .unwrap()
            .i64(0)
            .unwrap();
    let days = (exp - now_ms()) as f64 / DAY as f64;
    assert!(days > 29.0, "{days}");
    c.db.execute(
        "UPDATE sessions SET expires_at = $1",
        &vals![now_ms() - 1000],
    )
    .await
    .unwrap();
    let (s, ..) = c.call(Method::GET, "/v1/me", Some(&t), None).await;
    assert_eq!(s, StatusCode::UNAUTHORIZED);
    c.cleanup().await;
}

async fn expiry_and_cron(c: Ctx) {
    let t = c.register("a@example.com").await;
    let keep = c.upload(&t, 11).await;
    let old = c.upload(&t, 12).await;
    let old_id = old["id"].as_str().unwrap();
    let old_slug = old["slug"].as_str().unwrap();
    let old_key = c.key_of(old_id).await;
    // a stale pending row with an object, plus a fresh pending row that must survive
    let (_, _, p) = c
        .call(
            Method::POST,
            "/v1/screenshots",
            Some(&t),
            Some(json!({"content_type": "image/gif", "byte_size": 3})),
        )
        .await;
    let stale_key = c.key_of(p["id"].as_str().unwrap()).await;
    c.store.put(&stale_key, 3, "image/gif");
    c.db.execute(
        "UPDATE screenshots SET created_at = $1 WHERE id = $2",
        &vals![now_ms() - 2 * HOUR, p["id"].as_str().unwrap()],
    )
    .await
    .unwrap();
    let (_, _, fresh) = c
        .call(
            Method::POST,
            "/v1/screenshots",
            Some(&t),
            Some(json!({"content_type": "image/gif", "byte_size": 3})),
        )
        .await;
    // expired session
    c.db.execute(
        "INSERT INTO sessions (id, user_id, token_hash, created_at, last_used_at, expires_at) \
         SELECT $1, id, 'deadbeef', $2, $2, $3 FROM users",
        &vals![uuid::Uuid::new_v4(), now_ms() - 2 * DAY, now_ms() - DAY],
    )
    .await
    .unwrap();

    c.db.execute(
        "UPDATE screenshots SET expires_at = $1 WHERE id = $2",
        &vals![now_ms() - 60_000, old_id],
    )
    .await
    .unwrap();
    let (s, _, v) = c
        .call(Method::GET, &format!("/s/{old_slug}.png"), None, None)
        .await;
    assert_eq!(s, StatusCode::GONE);
    assert_eq!(v["error"]["code"], "GONE");
    let (_, _, l) = c.call(Method::GET, "/v1/screenshots", Some(&t), None).await;
    assert_eq!(l["items"].as_array().unwrap().len(), 1);

    // cron auth
    let (s, ..) = c
        .call(Method::POST, "/v1/internal/expire", None, None)
        .await;
    assert_eq!(s, StatusCode::UNAUTHORIZED);
    let (s, ..) = c
        .call(Method::POST, "/v1/internal/expire", Some("nope"), None)
        .await;
    assert_eq!(s, StatusCode::UNAUTHORIZED);

    // a storage failure must keep rows
    c.store.set_fail_deletes(true);
    let (s, ..) = c
        .call(
            Method::POST,
            "/v1/internal/expire",
            Some("cron-secret"),
            None,
        )
        .await;
    assert_eq!(s, StatusCode::BAD_GATEWAY);
    let n =
        c.db.query_one(
            "SELECT count(*) FROM screenshots WHERE id = $1",
            &vals![old_id],
        )
        .await
        .unwrap()
        .i64(0)
        .unwrap();
    assert_eq!(n, 1);
    c.store.set_fail_deletes(false);

    let (s, _, v) = c
        .call(
            Method::POST,
            "/v1/internal/expire",
            Some("cron-secret"),
            None,
        )
        .await;
    assert_eq!(s, StatusCode::OK, "{v}");
    assert_eq!(
        v,
        json!({"expired": 1, "purged_pending": 1, "purged_sessions": 1, "purged_users": 0, "expired_videos": 0, "aborted_uploads": 0, "more": false})
    );
    assert!(!c.store.contains(&old_key));
    assert!(!c.store.contains(&stale_key));
    assert!(
        c.store
            .contains(&c.key_of(keep["id"].as_str().unwrap()).await)
    );
    assert_eq!(c.count("screenshots").await, 2); // keep + fresh pending
    assert!(
        c.db.query_opt(
            "SELECT 1 FROM screenshots WHERE id = $1",
            &vals![fresh["id"].as_str().unwrap()]
        )
        .await
        .unwrap()
        .is_some()
    );
    let (s, ..) = c
        .call(Method::GET, &format!("/s/{old_slug}"), None, None)
        .await;
    assert_eq!(s, StatusCode::NOT_FOUND);

    // idempotent
    let (_, _, v) = c
        .call(
            Method::POST,
            "/v1/internal/expire",
            Some("cron-secret"),
            None,
        )
        .await;
    assert_eq!(
        v,
        json!({"expired": 0, "purged_pending": 0, "purged_sessions": 0, "purged_users": 0, "expired_videos": 0, "aborted_uploads": 0, "more": false})
    );
    c.cleanup().await;
}

async fn cron_disabled_without_secret(c: Ctx) {
    let c = c.reconfigure(|c| c.cron_secret = None);
    let (s, ..) = c
        .call(Method::POST, "/v1/internal/expire", Some("anything"), None)
        .await;
    assert_eq!(s, StatusCode::NOT_FOUND);
    c.cleanup().await;
}

async fn last_seen(c: &Ctx, email: &str) -> i64 {
    c.db.query_one(
        "SELECT last_seen_at FROM users WHERE email = $1",
        &vals![email],
    )
    .await
    .unwrap()
    .i64(0)
    .unwrap()
}

async fn backdate_user(c: &Ctx, email: &str, age_ms: i64) {
    c.db.execute(
        "UPDATE users SET last_seen_at = $1 WHERE email = $2",
        &vals![now_ms() - age_ms, email],
    )
    .await
    .unwrap();
}

async fn run_expire(c: &Ctx) -> (StatusCode, Value) {
    let (s, _, v) = c
        .call(
            Method::POST,
            "/v1/internal/expire",
            Some("cron-secret"),
            None,
        )
        .await;
    (s, v)
}

async fn last_seen_tracking(c: Ctx) {
    let t = c.register("a@example.com").await;
    let seen = last_seen(&c, "a@example.com").await;
    assert!((now_ms() - seen).abs() < 60_000);

    // login refreshes it
    backdate_user(&c, "a@example.com", 10 * DAY).await;
    let (s, ..) = c
        .call(
            Method::POST,
            "/v1/auth/login",
            None,
            Some(json!({"email": "a@example.com", "password": "supersecret123"})),
        )
        .await;
    assert_eq!(s, StatusCode::OK);
    assert!(now_ms() - last_seen(&c, "a@example.com").await < 60_000);

    // session use refreshes it, but at most hourly (piggybacking on the session throttle)
    let old = now_ms() - 10 * DAY;
    c.db.execute("UPDATE users SET last_seen_at = $1", &vals![old])
        .await
        .unwrap();
    c.call(Method::GET, "/v1/me", Some(&t), None).await;
    assert_eq!(
        last_seen(&c, "a@example.com").await,
        old,
        "session used <1h ago: no write"
    );
    c.db.execute(
        "UPDATE sessions SET last_used_at = $1",
        &vals![now_ms() - 2 * HOUR],
    )
    .await
    .unwrap();
    c.call(Method::GET, "/v1/me", Some(&t), None).await;
    assert!(now_ms() - last_seen(&c, "a@example.com").await < 60_000);

    // API token use refreshes it too
    let (_, _, v) = c
        .call(
            Method::POST,
            "/v1/tokens",
            Some(&t),
            Some(json!({"name": "x"})),
        )
        .await;
    let pat = v["token"].as_str().unwrap().to_string();
    c.db.execute("UPDATE users SET last_seen_at = $1", &vals![old])
        .await
        .unwrap();
    c.call(Method::GET, "/v1/me", Some(&pat), None).await; // first use of the token
    assert!(now_ms() - last_seen(&c, "a@example.com").await < 60_000);
    c.cleanup().await;
}

async fn inactive_user_purge(c: Ctx) {
    let stale = 91 * DAY;
    // gone: stale user with ready + pending screenshots, a token and sessions
    let gone_t = c.register("gone@example.com").await;
    let r1 = c.upload(&gone_t, 11).await;
    let r2 = c.upload(&gone_t, 12).await;
    let (_, _, p) = c
        .call(
            Method::POST,
            "/v1/screenshots",
            Some(&gone_t),
            Some(json!({"content_type": "image/png", "byte_size": 3})),
        )
        .await;
    let gone_keys = vec![
        c.key_of(r1["id"].as_str().unwrap()).await,
        c.key_of(r2["id"].as_str().unwrap()).await,
        c.key_of(p["id"].as_str().unwrap()).await,
    ];
    c.store.put(&gone_keys[2], 3, "image/png");
    c.call(
        Method::POST,
        "/v1/tokens",
        Some(&gone_t),
        Some(json!({"name": "t"})),
    )
    .await;
    c.call(
        Method::POST,
        "/v1/auth/login",
        None,
        Some(json!({"email": "gone@example.com", "password": "wrongwrongwrong"})),
    )
    .await;
    // kept: stale last_seen but an active session / api token proves activity
    let live_t = c.register("live@example.com").await;
    let live_shot = c.upload(&live_t, 21).await;
    let live_key = c.key_of(live_shot["id"].as_str().unwrap()).await;
    let pat_t = c.register("pat@example.com").await;
    let (_, _, v) = c
        .call(
            Method::POST,
            "/v1/tokens",
            Some(&pat_t),
            Some(json!({"name": "t"})),
        )
        .await;
    let pat = v["token"].as_str().unwrap().to_string();
    let fresh_t = c.register("fresh@example.com").await;
    let fresh_key = {
        let v = c.upload(&fresh_t, 31).await;
        c.key_of(v["id"].as_str().unwrap()).await
    };

    for e in ["gone@example.com", "live@example.com", "pat@example.com"] {
        backdate_user(&c, e, stale).await;
    }
    // live: session last used >1h ago, then it authenticates again
    c.db.execute(
        "UPDATE sessions SET last_used_at = $1 WHERE user_id IN (SELECT id FROM users WHERE email = $2)",
        &vals![now_ms() - 2 * HOUR, "live@example.com"],
    )
    .await
    .unwrap();
    let (s, ..) = c.call(Method::GET, "/v1/me", Some(&live_t), None).await;
    assert_eq!(s, StatusCode::OK);
    // pat: only an API token was used
    c.db.execute(
        "UPDATE api_tokens SET last_used_at = $1",
        &vals![now_ms() - 2 * HOUR],
    )
    .await
    .unwrap();
    let (s, ..) = c.call(Method::GET, "/v1/me", Some(&pat), None).await;
    assert_eq!(s, StatusCode::OK);

    // a store failure keeps everything for the next run
    c.store.set_fail_deletes(true);
    let (s, _) = run_expire(&c).await;
    assert_eq!(s, StatusCode::BAD_GATEWAY);
    assert_eq!(c.count("users").await, 4);
    assert_eq!(c.count("screenshots").await, 3 + 1 + 1);
    for k in &gone_keys {
        assert!(c.store.contains(k));
    }
    c.store.set_fail_deletes(false);

    let (s, v) = run_expire(&c).await;
    assert_eq!(s, StatusCode::OK, "{v}");
    assert_eq!(v["purged_users"], 1);
    assert_eq!(v["more"], false);
    for k in &gone_keys {
        assert!(!c.store.contains(k), "{k} should be deleted");
    }
    assert!(c.store.contains(&live_key) && c.store.contains(&fresh_key));
    assert_eq!(c.count("users").await, 3);
    assert_eq!(c.count("screenshots").await, 2);
    for table in ["sessions", "api_tokens", "login_attempts"] {
        let col = if table == "login_attempts" {
            "email = 'gone@example.com'"
        } else {
            "user_id IN (SELECT id FROM users WHERE email = 'gone@example.com')"
        };
        let n =
            c.db.query_one(&format!("SELECT count(*) FROM {table} WHERE {col}"), &[])
                .await
                .unwrap()
                .i64(0)
                .unwrap();
        assert_eq!(n, 0, "{table}");
    }
    // the purged user's credentials are dead, the others still work
    let (s, ..) = c.call(Method::GET, "/v1/me", Some(&gone_t), None).await;
    assert_eq!(s, StatusCode::UNAUTHORIZED);
    let (s, ..) = c.call(Method::GET, "/v1/me", Some(&live_t), None).await;
    assert_eq!(s, StatusCode::OK);
    // the email can be registered again
    c.register("gone@example.com").await;

    // idempotent
    let (_, v) = run_expire(&c).await;
    assert_eq!(v["purged_users"], 0);
    c.cleanup().await;
}

async fn inactive_purge_disabled_with_zero_days(c: Ctx) {
    let c = c.reconfigure(|c| c.inactive_user_days = 0);
    c.register("old@example.com").await;
    backdate_user(&c, "old@example.com", 1000 * DAY).await;
    let (s, v) = run_expire(&c).await;
    assert_eq!(s, StatusCode::OK);
    assert_eq!(v["purged_users"], 0);
    assert_eq!(c.count("users").await, 1);
    c.cleanup().await;
}

async fn unique_violation_mapping(c: Ctx) {
    let id = uuid::Uuid::new_v4();
    repo::create_user(&c.db, id, "u@example.com", "h", now_ms())
        .await
        .unwrap();
    let e = repo::create_user(&c.db, uuid::Uuid::new_v4(), "u@example.com", "h", now_ms())
        .await
        .unwrap_err();
    assert!(matches!(e, DbError::UniqueViolation), "{e:?}");
    // primary key too
    let e = repo::create_user(&c.db, id, "other@example.com", "h", now_ms())
        .await
        .unwrap_err();
    assert!(matches!(e, DbError::UniqueViolation), "{e:?}");
    // and over HTTP without mail: 409 EMAIL_TAKEN (with mail, register never tells)
    let (s, _, v) = c
        .call_via(
            &c.without_mail(),
            Method::POST,
            "/v1/auth/register",
            None,
            Some(json!({"email": "U@example.com", "password": "supersecret123"})),
        )
        .await;
    assert_eq!(
        (s, v["error"]["code"].as_str()),
        (StatusCode::CONFLICT, Some("EMAIL_TAKEN"))
    );
    c.cleanup().await;
}

async fn portable_layer(c: Ctx) {
    // NULL binds, mixed types, count/sum normalisation, IN lists beyond one chunk
    let user = uuid::Uuid::new_v4();
    let now = now_ms();
    let mut ids = vec![];
    for i in 0..450 {
        let id = uuid::Uuid::new_v4();
        ids.push(id);
        let slug = format!("slug{i}");
        let key = format!("k/{i}");
        let ok = repo::insert_screenshot(
            &c.db,
            &repo::NewScreenshot {
                id,
                user_id: user,
                slug: &slug,
                object_key: &key,
                content_type: "image/png",
                byte_size: 5_000_000_000 + i,
                width: None,
                height: Some(7),
                filename: None,
                now,
                expires_at: now + DAY,
            },
        )
        .await
        .unwrap();
        assert!(ok);
    }
    // duplicate slug is reported, not an error
    let dup = repo::insert_screenshot(
        &c.db,
        &repo::NewScreenshot {
            id: uuid::Uuid::new_v4(),
            user_id: user,
            slug: "slug0",
            object_key: "k/x",
            content_type: "image/png",
            byte_size: 1,
            width: Some(1),
            height: None,
            filename: Some("f"),
            now,
            expires_at: now + DAY,
        },
    )
    .await
    .unwrap();
    assert!(!dup);
    let r =
        c.db.query_one(
            "SELECT width, height, filename, byte_size FROM screenshots WHERE slug = $1",
            &vals!["slug3"],
        )
        .await
        .unwrap();
    assert_eq!(
        (
            r.opt_i64(0).unwrap(),
            r.opt_i64(1).unwrap(),
            r.opt_text(2).unwrap()
        ),
        (None, Some(7), None)
    );
    assert_eq!(r.i64(3).unwrap(), 5_000_000_003);
    assert_eq!(c.count("screenshots").await, 450);
    repo::delete_screenshots_by_ids(&c.db, &ids[..401])
        .await
        .unwrap();
    assert_eq!(c.count("screenshots").await, 49);
    repo::delete_screenshots_by_ids(&c.db, &ids).await.unwrap(); // idempotent
    repo::delete_screenshots_by_ids(&c.db, &[]).await.unwrap();
    assert_eq!(c.count("screenshots").await, 0);
    let (n, bytes) = repo::usage(&c.db, user, now).await.unwrap();
    assert_eq!((n, bytes), (0, 0));
    c.cleanup().await;
}

/// Confirmation from an existing (pre-verification) session: not a claim, so the session
/// and the password stay.
async fn email_verification(c: Ctx) {
    let t = c
        .unverified_session("v@example.com", "supersecret123")
        .await;
    let (s, ..) = c
        .post("/v1/auth/verify-email/send", Some(&t), json!({}))
        .await;
    assert_eq!(s, StatusCode::ACCEPTED);
    let code = c.next_code("v@example.com").await;
    let (_, _, me) = c.call(Method::GET, "/v1/me", Some(&t), None).await;
    assert_eq!(me["email_verified"], false);

    let wrong = if code == "000000" { "000001" } else { "000000" };
    let (s, v) = c
        .post(
            "/v1/auth/verify-email/confirm",
            Some(&t),
            json!({"code": wrong}),
        )
        .await;
    assert_eq!(
        (s, v["error"]["code"].as_str()),
        (StatusCode::UNAUTHORIZED, Some("INVALID_CODE"))
    );
    let (s, v) = c
        .post(
            "/v1/auth/verify-email/confirm",
            Some(&t),
            json!({"code": "12ab"}),
        )
        .await;
    assert_eq!(
        (s, v["error"]["code"].as_str()),
        (StatusCode::UNAUTHORIZED, Some("INVALID_CODE"))
    );
    let (s, v) = c
        .post(
            "/v1/auth/verify-email/confirm",
            Some(&t),
            json!({"code": code}),
        )
        .await;
    assert_eq!(
        (s, v["email_verified"].as_bool()),
        (StatusCode::OK, Some(true))
    );
    let (_, _, me) = c.call(Method::GET, "/v1/me", Some(&t), None).await;
    assert_eq!(me["email_verified"], true);

    let (s, v) = c
        .post("/v1/auth/verify-email/send", Some(&t), json!({}))
        .await;
    assert_eq!(
        (s, v["status"].as_str()),
        (StatusCode::OK, Some("already_verified"))
    );
    let (s, ..) = c.post("/v1/auth/verify-email/send", None, json!({})).await;
    assert_eq!(s, StatusCode::UNAUTHORIZED);
    let (s, _) = c
        .post(
            "/v1/auth/login",
            None,
            json!({"email": "v@example.com", "password": "supersecret123"}),
        )
        .await;
    assert_eq!(s, StatusCode::OK);
    c.cleanup().await;
}

async fn verification_gate(c: Ctx) {
    let c = c.reconfigure(|cfg| cfg.require_email_verification = true);
    let t = c
        .unverified_session("g@example.com", "supersecret123")
        .await;
    c.post("/v1/auth/verify-email/send", Some(&t), json!({}))
        .await;
    let code = c.next_code("g@example.com").await;
    let body = json!({"content_type": "image/png", "byte_size": 10});
    let (s, v) = c.post("/v1/screenshots", Some(&t), body.clone()).await;
    assert_eq!(
        (s, v["error"]["code"].as_str()),
        (StatusCode::FORBIDDEN, Some("EMAIL_NOT_VERIFIED"))
    );
    // resend is rate limited, then allowed after the cooldown
    c.post("/v1/auth/verify-email/send", Some(&t), json!({}))
        .await;
    c.assert_no_mail().await;
    c.age_codes(60_000).await;
    let (s, ..) = c
        .post("/v1/auth/verify-email/send", Some(&t), json!({}))
        .await;
    assert_eq!(s, StatusCode::ACCEPTED);
    let newer = c.next_code("g@example.com").await;
    // the superseded code no longer works (unless it collides with the new one)
    if newer != code {
        let (s, ..) = c
            .post(
                "/v1/auth/verify-email/confirm",
                Some(&t),
                json!({"code": code}),
            )
            .await;
        assert_eq!(s, StatusCode::UNAUTHORIZED);
    }
    let (s, ..) = c
        .post(
            "/v1/auth/verify-email/confirm",
            Some(&t),
            json!({"code": newer}),
        )
        .await;
    assert_eq!(s, StatusCode::OK);
    let (s, ..) = c.post("/v1/screenshots", Some(&t), body).await;
    assert_eq!(s, StatusCode::CREATED);
    c.cleanup().await;
}

async fn password_reset_flow(c: Ctx) {
    let old = c.register("r@example.com").await;
    let (s, v) = c
        .post("/v1/tokens", Some(&old), json!({"name": "ci"}))
        .await;
    assert_eq!(s, StatusCode::CREATED, "{v}");
    let pat = v["token"].as_str().unwrap().to_string();

    // unknown account: same answer, no mail
    let (s, v) = c
        .post(
            "/v1/auth/password/forgot",
            None,
            json!({"email": "nobody@example.com"}),
        )
        .await;
    assert_eq!(
        (s, v["status"].as_str()),
        (StatusCode::ACCEPTED, Some("sent_if_account_exists"))
    );
    c.assert_no_mail().await;
    let (s, ..) = c
        .post(
            "/v1/auth/password/forgot",
            None,
            json!({"email": "not-an-email"}),
        )
        .await;
    assert_eq!(s, StatusCode::BAD_REQUEST);

    let (s, ..) = c
        .post(
            "/v1/auth/password/forgot",
            None,
            json!({"email": "R@example.com"}),
        )
        .await;
    assert_eq!(s, StatusCode::ACCEPTED);
    let code = c.next_code("r@example.com").await;

    let reset = |email: &str, code: &str, pw: &str| json!({"email": email, "code": code, "new_password": pw});
    let wrong = if code == "000000" { "000001" } else { "000000" };
    let (s, ..) = c
        .post(
            "/v1/auth/password/reset",
            None,
            reset("r@example.com", wrong, "brand-new-password"),
        )
        .await;
    assert_eq!(s, StatusCode::UNAUTHORIZED);
    let (s, ..) = c
        .post(
            "/v1/auth/password/reset",
            None,
            reset("r@example.com", &code, "short"),
        )
        .await;
    assert_eq!(s, StatusCode::BAD_REQUEST);
    let (s, ..) = c
        .post(
            "/v1/auth/password/reset",
            None,
            reset("other@example.com", &code, "brand-new-password"),
        )
        .await;
    assert_eq!(s, StatusCode::UNAUTHORIZED);
    let (s, ..) = c
        .post(
            "/v1/auth/password/reset",
            None,
            reset("r@example.com", &code, "brand-new-password"),
        )
        .await;
    assert_eq!(s, StatusCode::NO_CONTENT);
    // single use
    let (s, ..) = c
        .post(
            "/v1/auth/password/reset",
            None,
            reset("r@example.com", &code, "another-password-1"),
        )
        .await;
    assert_eq!(s, StatusCode::UNAUTHORIZED);

    // old sessions and API tokens are revoked, old password is dead, new one works
    let (s, ..) = c.call(Method::GET, "/v1/me", Some(&old), None).await;
    assert_eq!(s, StatusCode::UNAUTHORIZED);
    let (s, ..) = c.call(Method::GET, "/v1/me", Some(&pat), None).await;
    assert_eq!(s, StatusCode::UNAUTHORIZED);
    let (s, ..) = c
        .post(
            "/v1/auth/login",
            None,
            json!({"email": "r@example.com", "password": "supersecret123"}),
        )
        .await;
    assert_eq!(s, StatusCode::UNAUTHORIZED);
    let (s, v) = c
        .post(
            "/v1/auth/login",
            None,
            json!({"email": "r@example.com", "password": "brand-new-password"}),
        )
        .await;
    assert_eq!(s, StatusCode::OK);
    assert_eq!(v["user"]["email_verified"], true);
    c.cleanup().await;
}

async fn otp_login_flow(c: Ctx) {
    c.register("o@example.com").await;

    let (s, ..) = c
        .post(
            "/v1/auth/otp/request",
            None,
            json!({"email": "nobody@example.com"}),
        )
        .await;
    assert_eq!(s, StatusCode::ACCEPTED);
    c.assert_no_mail().await;
    let (s, v) = c
        .post(
            "/v1/auth/otp/verify",
            None,
            json!({"email": "nobody@example.com", "code": "123456"}),
        )
        .await;
    assert_eq!(
        (s, v["error"]["code"].as_str()),
        (StatusCode::UNAUTHORIZED, Some("INVALID_CODE"))
    );

    let (s, ..) = c
        .post(
            "/v1/auth/otp/request",
            None,
            json!({"email": "O@example.com"}),
        )
        .await;
    assert_eq!(s, StatusCode::ACCEPTED);
    let code = c.next_code("o@example.com").await;
    let wrong = if code == "000000" { "000001" } else { "000000" };

    // guesses are capped per code: after 5 wrong tries even the right code is rejected
    for _ in 0..5 {
        let (s, ..) = c
            .post(
                "/v1/auth/otp/verify",
                None,
                json!({"email": "o@example.com", "code": wrong}),
            )
            .await;
        assert_eq!(s, StatusCode::UNAUTHORIZED);
    }
    let (s, ..) = c
        .post(
            "/v1/auth/otp/verify",
            None,
            json!({"email": "o@example.com", "code": code}),
        )
        .await;
    assert_eq!(s, StatusCode::UNAUTHORIZED);

    // a fresh code (after the cooldown) signs in, once
    c.age_codes(60_000).await;
    c.post(
        "/v1/auth/otp/request",
        None,
        json!({"email": "o@example.com"}),
    )
    .await;
    let code = c.next_code("o@example.com").await;
    let (s, v) = c
        .post(
            "/v1/auth/otp/verify",
            None,
            json!({"email": "o@example.com", "code": code, "device_name": "mac"}),
        )
        .await;
    assert_eq!(s, StatusCode::OK, "{v}");
    let t = v["token"].as_str().unwrap();
    assert!(t.starts_with("sgs_"));
    assert_eq!(v["user"]["email_verified"], true);
    let (s, ..) = c.call(Method::GET, "/v1/me", Some(t), None).await;
    assert_eq!(s, StatusCode::OK);
    let (s, ..) = c
        .post(
            "/v1/auth/otp/verify",
            None,
            json!({"email": "o@example.com", "code": code}),
        )
        .await;
    assert_eq!(s, StatusCode::UNAUTHORIZED);
    c.cleanup().await;
}

async fn codes_expire_and_are_cleaned(c: Ctx) {
    let t = c
        .unverified_session("e@example.com", "supersecret123")
        .await;
    c.post("/v1/auth/verify-email/send", Some(&t), json!({}))
        .await;
    let code = c.next_code("e@example.com").await;
    c.db.execute(
        "UPDATE auth_codes SET expires_at = $1",
        &vals![now_ms() - 1],
    )
    .await
    .unwrap();
    let (s, ..) = c
        .post(
            "/v1/auth/verify-email/confirm",
            Some(&t),
            json!({"code": code}),
        )
        .await;
    assert_eq!(s, StatusCode::UNAUTHORIZED);
    c.db.execute(
        "UPDATE auth_codes SET expires_at = $1",
        &vals![now_ms() - 2 * DAY],
    )
    .await
    .unwrap();
    let (s, ..) = c
        .call(
            Method::POST,
            "/v1/internal/expire",
            Some("cron-secret"),
            None,
        )
        .await;
    assert_eq!(s, StatusCode::OK);
    assert_eq!(c.count("auth_codes").await, 0);
    c.cleanup().await;
}

async fn mail_disabled_returns_503(c: Ctx) {
    let app = router(AppState::new(c.db.clone(), c.store.clone(), c.cfg.clone()));
    for (path, body) in [
        (
            "/v1/auth/password/forgot",
            json!({"email": "a@example.com"}),
        ),
        ("/v1/auth/otp/request", json!({"email": "a@example.com"})),
    ] {
        let req = Request::builder()
            .method(Method::POST)
            .uri(path)
            .header(header::CONTENT_TYPE, "application/json")
            .body(Body::from(body.to_string()))
            .unwrap();
        let res = app.clone().oneshot(req).await.unwrap();
        assert_eq!(res.status(), StatusCode::SERVICE_UNAVAILABLE);
    }
    // registration still works without mail
    let (s, ..) = app
        .clone()
        .oneshot(
            Request::builder()
                .method(Method::POST)
                .uri("/v1/auth/register")
                .header(header::CONTENT_TYPE, "application/json")
                .body(Body::from(
                    json!({"email": "n@example.com", "password": "supersecret123"}).to_string(),
                ))
                .unwrap(),
        )
        .await
        .map(|r| (r.status(), ()))
        .unwrap();
    assert_eq!(s, StatusCode::CREATED);
    c.cleanup().await;
}

fn login_body(email: &str, password: &str) -> Value {
    json!({"email": email, "password": password})
}

/// Mail on: registering never signs in; the right password before verification mails a
/// code instead of a session; that code confirms the account and keeps the password.
async fn unverified_accounts_hold_no_credentials(c: Ctx) {
    let (s, _, v) = c
        .call(
            Method::POST,
            "/v1/auth/register",
            None,
            Some(login_body("n@example.com", "supersecret123")),
        )
        .await;
    assert_eq!(s, StatusCode::ACCEPTED, "{v}");
    assert_eq!(v["verification_required"], true);
    assert_eq!(v["attempt"].as_str().unwrap().len(), 43);
    assert!(v.get("token").is_none());
    let first = c.next_code("n@example.com").await;
    c.age_codes(60_000).await;
    let (s, v) = c
        .post(
            "/v1/auth/login",
            None,
            login_body("n@example.com", "supersecret123"),
        )
        .await;
    assert_eq!(s, StatusCode::ACCEPTED);
    let attempt = v["attempt"].as_str().unwrap().to_owned();
    let code = c.next_code("n@example.com").await;
    let (s, _) = c
        .post(
            "/v1/auth/login",
            None,
            login_body("n@example.com", "wrong-password"),
        )
        .await;
    assert_eq!(s, StatusCode::UNAUTHORIZED);
    c.assert_no_mail().await;
    if first != code {
        let (s, _) = c
            .post(
                "/v1/auth/otp/verify",
                None,
                json!({"email": "n@example.com", "code": first}),
            )
            .await;
        assert_eq!(s, StatusCode::UNAUTHORIZED, "superseded code");
    }
    let (s, v) = c
        .post(
            "/v1/auth/otp/verify",
            None,
            json!({"email": "n@example.com", "code": code, "device_name": "mac", "attempt": attempt}),
        )
        .await;
    assert_eq!(s, StatusCode::OK, "{v}");
    assert_eq!(v["user"]["email_verified"], true);
    let t = v["token"].as_str().unwrap();
    let (s, ..) = c.call(Method::GET, "/v1/me", Some(t), None).await;
    assert_eq!(s, StatusCode::OK);
    let (s, v) = c
        .post(
            "/v1/auth/login",
            None,
            login_body("n@example.com", "supersecret123"),
        )
        .await;
    assert_eq!(
        (s, v["user"]["email_verified"].as_bool()),
        (StatusCode::OK, Some(true))
    );
    c.cleanup().await;
}

/// Pre-registration takeover over the API: whoever registered the address first (even
/// holding a session and an API token, here made while mail was off) loses every
/// credential when the mailbox owner confirms it, and the owner's password is the one the
/// owner chose. A sign-in code claims too, leaving no usable password.
async fn verification_claims_unverified_account(c: Ctx) {
    let email = "victim@example.com";
    let attacker = c.unverified_session(email, "attacker-password").await;
    let (s, _, v) = c
        .call_via(
            &c.without_mail(),
            Method::POST,
            "/v1/tokens",
            Some(&attacker),
            Some(json!({"name": "planted"})),
        )
        .await;
    assert_eq!(s, StatusCode::CREATED, "{v}");
    let pat = v["token"].as_str().unwrap().to_string();
    // With mail on, no new token for an unverified account.
    let (s, _) = c
        .post("/v1/tokens", Some(&attacker), json!({"name": "more"}))
        .await;
    assert_eq!(s, StatusCode::FORBIDDEN);

    let (s, pending) = c
        .post(
            "/v1/auth/register",
            None,
            login_body(email, "victim-password"),
        )
        .await;
    assert_eq!(s, StatusCode::ACCEPTED);
    let code = c.next_code(email).await;
    let (s, v) = c
        .post(
            "/v1/auth/otp/verify",
            None,
            json!({"email": email, "code": code, "attempt": pending["attempt"]}),
        )
        .await;
    assert_eq!(s, StatusCode::OK, "{v}");
    let owner = v["token"].as_str().unwrap().to_string();
    for t in [&attacker, &pat] {
        let (s, ..) = c.call(Method::GET, "/v1/me", Some(t), None).await;
        assert_eq!(s, StatusCode::UNAUTHORIZED);
    }
    let (s, ..) = c.call(Method::GET, "/v1/me", Some(&owner), None).await;
    assert_eq!(s, StatusCode::OK);
    let (s, _) = c
        .post(
            "/v1/auth/login",
            None,
            login_body(email, "attacker-password"),
        )
        .await;
    assert_eq!(s, StatusCode::UNAUTHORIZED);
    let (s, _) = c
        .post("/v1/auth/login", None, login_body(email, "victim-password"))
        .await;
    assert_eq!(s, StatusCode::OK);

    let other = "other@example.com";
    let planted = c.unverified_session(other, "attacker-password").await;
    let (s, _) = c
        .post("/v1/auth/otp/request", None, json!({"email": other}))
        .await;
    assert_eq!(s, StatusCode::ACCEPTED);
    let code = c.next_code(other).await;
    let (s, v) = c
        .post(
            "/v1/auth/otp/verify",
            None,
            json!({"email": other, "code": code}),
        )
        .await;
    assert_eq!(s, StatusCode::OK, "{v}");
    let (s, ..) = c.call(Method::GET, "/v1/me", Some(&planted), None).await;
    assert_eq!(s, StatusCode::UNAUTHORIZED);
    let (s, _) = c
        .post(
            "/v1/auth/login",
            None,
            login_body(other, "attacker-password"),
        )
        .await;
    assert_eq!(s, StatusCode::UNAUTHORIZED);
    let hash =
        c.db.query_one(
            "SELECT password_hash FROM users WHERE email = $1",
            &vals![other],
        )
        .await
        .unwrap()
        .text(0)
        .unwrap();
    assert_eq!(hash, easyshot_server::auth::UNUSABLE_PASSWORD);
    c.cleanup().await;
}

/// Sign-ups and code requests are budgeted per client address before any hashing,
/// account creation or mail.
async fn auth_limits_per_address(c: Ctx) {
    for i in 0..5 {
        let (s, _) = c
            .post(
                "/v1/auth/register",
                None,
                login_body(&format!("u{i}@example.com"), "supersecret123"),
            )
            .await;
        assert_eq!(s, StatusCode::ACCEPTED);
    }
    let (s, v) = c
        .post(
            "/v1/auth/register",
            None,
            login_body("u5@example.com", "supersecret123"),
        )
        .await;
    assert_eq!(
        (s, v["error"]["code"].as_str()),
        (StatusCode::TOO_MANY_REQUESTS, Some("RATE_LIMITED"))
    );
    assert_eq!(c.count("users").await, 5);
    for _ in 0..10 {
        let (s, _) = c
            .post(
                "/v1/auth/otp/request",
                None,
                json!({"email": "u0@example.com"}),
            )
            .await;
        assert_eq!(s, StatusCode::ACCEPTED);
    }
    let (s, _) = c
        .post(
            "/v1/auth/password/forgot",
            None,
            json!({"email": "u0@example.com"}),
        )
        .await;
    assert_eq!(s, StatusCode::TOO_MANY_REQUESTS);
    c.cleanup().await;
}

/// Concurrent wrong guesses cannot exceed the per-account failure limit: every attempt is
/// recorded before its password is checked.
async fn concurrent_login_failures_are_all_counted(c: Ctx) {
    c.register("a@example.com").await;
    let calls = (0..18).map(|_| {
        c.post(
            "/v1/auth/login",
            None,
            login_body("a@example.com", "wrong-password"),
        )
    });
    let statuses: Vec<StatusCode> = futures_util::future::join_all(calls)
        .await
        .into_iter()
        .map(|(s, _)| s)
        .collect();
    let checked = statuses
        .iter()
        .filter(|s| **s == StatusCode::UNAUTHORIZED)
        .count();
    assert!(checked <= 10, "{statuses:?}");
    assert!(
        statuses
            .iter()
            .all(|s| matches!(*s, StatusCode::UNAUTHORIZED | StatusCode::TOO_MANY_REQUESTS))
    );
    let (s, _) = c
        .post(
            "/v1/auth/login",
            None,
            login_body("a@example.com", "supersecret123"),
        )
        .await;
    assert_eq!(s, StatusCode::TOO_MANY_REQUESTS);
    c.cleanup().await;
}

/// Independent password-carrying codes cannot cross attempts, resends retain the same
/// binding, and exactly one concurrent redemption succeeds.
async fn signup_codes_are_bound_to_the_requesting_attempt(c: Ctx) {
    let email = "bound@example.com";
    let (_, first) = c
        .post(
            "/v1/auth/register",
            None,
            login_body(email, "owner-password"),
        )
        .await;
    let code = c.next_code(email).await;
    let first_attempt = first["attempt"].clone();
    c.age_codes(60_000).await;
    let (_, second) = c
        .post(
            "/v1/auth/register",
            None,
            login_body(email, "attacker-password"),
        )
        .await;
    let other_code = c.next_code(email).await;
    let second_attempt = second["attempt"].clone();
    assert_ne!(first_attempt, second_attempt);
    for attempt in [Value::Null, json!("wrong-nonce")] {
        let (s, _) = c
            .post(
                "/v1/auth/otp/verify",
                None,
                json!({"email": email, "code": code, "attempt": attempt}),
            )
            .await;
        assert_eq!(s, StatusCode::UNAUTHORIZED);
    }
    if code != other_code {
        for (submitted, attempt) in [(&code, &second_attempt), (&other_code, &first_attempt)] {
            let (s, _) = c
                .post(
                    "/v1/auth/otp/verify",
                    None,
                    json!({"email": email, "code": submitted, "attempt": attempt}),
                )
                .await;
            assert_eq!(s, StatusCode::UNAUTHORIZED);
        }
    }
    // Resending the owner's code cannot discard the password or move it to another nonce.
    c.age_codes(60_000).await;
    c.post(
        "/v1/auth/otp/request",
        None,
        json!({"email": email, "attempt": first_attempt}),
    )
    .await;
    let resent = c.next_code(email).await;
    let body = json!({"email": email, "code": resent, "attempt": first_attempt});
    let (a, b) = tokio::join!(
        c.post("/v1/auth/otp/verify", None, body.clone()),
        c.post("/v1/auth/otp/verify", None, body)
    );
    let mut statuses = [a.0, b.0];
    statuses.sort();
    assert_eq!(statuses, [StatusCode::OK, StatusCode::UNAUTHORIZED]);
    assert_eq!(
        c.post("/v1/auth/login", None, login_body(email, "owner-password"))
            .await
            .0,
        StatusCode::OK
    );
    assert_eq!(
        c.post(
            "/v1/auth/login",
            None,
            login_body(email, "attacker-password")
        )
        .await
        .0,
        StatusCode::UNAUTHORIZED
    );
    // Claiming invalidated every still-live code from competing attempts.
    assert_eq!(
        c.post(
            "/v1/auth/otp/verify",
            None,
            json!({"email": email, "code": other_code, "attempt": second_attempt})
        )
        .await
        .0,
        StatusCode::UNAUTHORIZED
    );
    c.cleanup().await;
}

async fn recovery_invalidates_outstanding_sign_in_codes(c: Ctx) {
    let email = "recover@example.com";
    c.register(email).await;
    c.post("/v1/auth/otp/request", None, json!({"email": email}))
        .await;
    let stale = c.next_code(email).await;
    c.post("/v1/auth/password/forgot", None, json!({"email": email}))
        .await;
    let reset = c.next_code(email).await;
    let (s, _) = c
        .post(
            "/v1/auth/password/reset",
            None,
            json!({"email": email, "code": reset, "new_password": "recovered-password"}),
        )
        .await;
    assert_eq!(s, StatusCode::NO_CONTENT);
    let (s, _) = c
        .post(
            "/v1/auth/otp/verify",
            None,
            json!({"email": email, "code": stale}),
        )
        .await;
    assert_eq!(s, StatusCode::UNAUTHORIZED);
    c.cleanup().await;
}

macro_rules! suite {
    ($($name:ident),* $(,)?) => {$(
        mod $name {
            use super::*;
            #[tokio::test]
            async fn postgres() {
                super::$name(Ctx::postgres().await).await;
            }
        }
    )*};
}

suite!(
    healthz,
    register_login_me,
    register_validation_and_duplicates,
    signups_disabled,
    bad_password_and_throttle,
    screenshot_lifecycle,
    create_validation,
    size_mismatch,
    cross_user_denied,
    pagination,
    api_tokens,
    disabled_user_rejected,
    session_sliding_expiry,
    expiry_and_cron,
    cron_disabled_without_secret,
    last_seen_tracking,
    inactive_user_purge,
    inactive_purge_disabled_with_zero_days,
    unique_violation_mapping,
    portable_layer,
    email_verification,
    verification_gate,
    password_reset_flow,
    otp_login_flow,
    codes_expire_and_are_cleaned,
    mail_disabled_returns_503,
    unverified_accounts_hold_no_credentials,
    verification_claims_unverified_account,
    auth_limits_per_address,
    concurrent_login_failures_are_all_counted,
    signup_codes_are_bound_to_the_requesting_attempt,
    recovery_invalidates_outstanding_sign_in_codes,
);

#[tokio::test]
async fn lettermint_client_request_shape() {
    use std::sync::Mutex;
    type Seen = Arc<Mutex<Vec<(axum::http::HeaderMap, Value)>>>;
    let seen: Seen = Default::default();
    let app = Router::new()
        .route(
            "/v1/send",
            axum::routing::post(
                |axum::extract::State(seen): axum::extract::State<Seen>,
                 headers: axum::http::HeaderMap,
                 axum::Json(body): axum::Json<Value>| async move {
                    seen.lock().unwrap().push((headers, body));
                    (
                        StatusCode::ACCEPTED,
                        axum::Json(json!({"message_id": "m1", "status": "pending"})),
                    )
                },
            ),
        )
        .route(
            "/bad/send",
            axum::routing::post(|| async {
                (
                    StatusCode::UNPROCESSABLE_ENTITY,
                    "recipient=u@example.com code=424242 token=lm_secret",
                )
            }),
        )
        .with_state(seen.clone());
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });

    let mail = easyshot_server::mailer::code_email(
        easyshot_server::mailer::CodePurpose::LoginOtp,
        "u@example.com",
        "424242",
        10,
        "k",
    );
    let m = LettermintMailer::new(
        &format!("http://{addr}/v1"),
        "lm_secret",
        "Easyshot <no-reply@example.com>",
        Some("outbound"),
    );
    m.send(mail.clone()).await.unwrap();
    let (headers, body) = seen.lock().unwrap()[0].clone();
    assert_eq!(headers["x-lettermint-token"], "lm_secret");
    assert_eq!(headers["idempotency-key"], "login_otp-k");
    assert_eq!(body["to"], json!(["u@example.com"]));
    assert_eq!(body["from"], "Easyshot <no-reply@example.com>");
    assert_eq!(body["route"], "outbound");
    assert!(body["text"].as_str().unwrap().contains("424242"));

    let bad = LettermintMailer::new(&format!("http://{addr}/bad"), "t", "a@b.c", None);
    let err = bad.send(mail).await.unwrap_err().to_string();
    assert!(err.contains("422"), "{err}");
    for sensitive in ["u@example.com", "424242", "lm_secret"] {
        assert!(!err.contains(sensitive));
    }
    // Unset routing delegates to the project's real default; never invent a route slug.
    let mut cfg = Config::for_tests("unused");
    cfg.lettermint_api_token = Some("lm_secret".into());
    cfg.mail_from = Some("Easyshot <no-reply@example.com>".into());
    cfg.lettermint_api_url = format!("http://{addr}/v1");
    LettermintMailer::from_config(&cfg)
        .unwrap()
        .send(easyshot_server::mailer::code_email(
            easyshot_server::mailer::CodePurpose::LoginOtp,
            "u@example.com",
            "424242",
            10,
            "k2",
        ))
        .await
        .unwrap();
    assert!(
        seen.lock()
            .unwrap()
            .last()
            .unwrap()
            .1
            .get("route")
            .is_none()
    );
}
