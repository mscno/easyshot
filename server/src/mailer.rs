//! Transactional email. Production uses Lettermint's HTTP API; tests use `MemoryMailer`.
//! When no API token is configured the server runs with `DisabledMailer` and the
//! email-based endpoints answer 503.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use serde_json::json;

use crate::config::Config;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Email {
    pub to: String,
    pub subject: String,
    pub text: String,
    pub html: String,
    /// Stable per logical message so provider-side retries don't send duplicates.
    pub idempotency_key: String,
}

#[derive(Debug)]
pub struct MailError(pub String);

impl std::fmt::Display for MailError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

#[async_trait]
pub trait Mailer: Send + Sync {
    fn enabled(&self) -> bool {
        true
    }
    async fn send(&self, email: Email) -> Result<(), MailError>;
}

pub struct DisabledMailer;

#[async_trait]
impl Mailer for DisabledMailer {
    fn enabled(&self) -> bool {
        false
    }
    async fn send(&self, _: Email) -> Result<(), MailError> {
        Err(MailError("email is not configured".into()))
    }
}

/// Lettermint send API: `POST {api_url}/send` with the project token in `x-lettermint-token`.
pub struct LettermintMailer {
    http: reqwest::Client,
    api_url: String,
    token: String,
    from: String,
    route: Option<String>,
}

impl LettermintMailer {
    pub fn new(api_url: &str, token: &str, from: &str, route: Option<&str>) -> Self {
        let http = reqwest::Client::builder()
            .timeout(Duration::from_secs(15))
            .build()
            .expect("http client");
        Self {
            http,
            api_url: api_url.trim_end_matches('/').to_string(),
            token: token.to_string(),
            from: from.to_string(),
            route: route.map(str::to_string),
        }
    }

    /// `None` when `LETTERMINT_API_TOKEN` is unset.
    pub fn from_config(cfg: &Config) -> Option<Self> {
        let token = cfg.lettermint_api_token.as_deref()?;
        Some(Self::new(
            &cfg.lettermint_api_url,
            token,
            cfg.mail_from.as_deref()?,
            cfg.lettermint_route.as_deref(),
        ))
    }

    pub fn payload(&self, e: &Email) -> serde_json::Value {
        let mut body = json!({
            "from": self.from,
            "to": [e.to],
            "subject": e.subject,
            "text": e.text,
            "html": e.html,
        });
        if let Some(route) = &self.route {
            body["route"] = json!(route);
        }
        body
    }
}

#[async_trait]
impl Mailer for LettermintMailer {
    async fn send(&self, email: Email) -> Result<(), MailError> {
        let res = self
            .http
            .post(format!("{}/send", self.api_url))
            .header("x-lettermint-token", &self.token)
            .header("Idempotency-Key", &email.idempotency_key)
            .json(&self.payload(&email))
            .send()
            .await
            .map_err(|e| MailError(format!("lettermint request failed: {e}")))?;
        let status = res.status();
        if status.is_success() {
            return Ok(());
        }
        // The body can echo request fields; log only its size-limited prefix.
        let body = res.text().await.unwrap_or_default();
        let body: String = body.chars().take(300).collect();
        Err(MailError(format!("lettermint returned {status}: {body}")))
    }
}

/// Records messages instead of sending them.
#[derive(Default)]
pub struct MemoryMailer {
    sent: Mutex<Vec<Email>>,
}

impl MemoryMailer {
    pub fn new() -> Arc<Self> {
        Arc::new(Self::default())
    }
    pub fn sent(&self) -> Vec<Email> {
        self.sent.lock().unwrap().clone()
    }
    pub fn clear(&self) {
        self.sent.lock().unwrap().clear();
    }
}

#[async_trait]
impl Mailer for MemoryMailer {
    async fn send(&self, email: Email) -> Result<(), MailError> {
        self.sent.lock().unwrap().push(email);
        Ok(())
    }
}

// ---------- templates ----------

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CodePurpose {
    VerifyEmail,
    ResetPassword,
    LoginOtp,
}

impl CodePurpose {
    pub fn as_str(self) -> &'static str {
        match self {
            CodePurpose::VerifyEmail => "verify_email",
            CodePurpose::ResetPassword => "reset_password",
            CodePurpose::LoginOtp => "login_otp",
        }
    }
}

pub fn code_email(
    purpose: CodePurpose,
    to: &str,
    code: &str,
    ttl_minutes: i64,
    key: &str,
) -> Email {
    let (subject, intro) = match purpose {
        CodePurpose::VerifyEmail => (
            "Confirm your Easyshot email",
            "Enter this code in Easyshot to confirm your email address.",
        ),
        CodePurpose::ResetPassword => (
            "Reset your Easyshot password",
            "Enter this code in Easyshot to choose a new password.",
        ),
        CodePurpose::LoginOtp => (
            "Your Easyshot sign-in code",
            "Enter this code in Easyshot to sign in.",
        ),
    };
    let footer = match purpose {
        CodePurpose::VerifyEmail => "If you didn't create a Easyshot account, ignore this email.",
        _ => "If you didn't request this, you can ignore this email. Your account is safe.",
    };
    let text = format!(
        "{intro}\n\n    {code}\n\nThe code expires in {ttl_minutes} minutes and works once.\n{footer}\n"
    );
    let html = format!(
        "<div style=\"font-family:-apple-system,Helvetica,Arial,sans-serif;max-width:420px;margin:0 auto;padding:24px;color:#1d1d1f\">\
         <p>{intro}</p>\
         <p style=\"font-size:32px;letter-spacing:8px;font-weight:600;margin:24px 0\">{code}</p>\
         <p style=\"color:#6e6e73;font-size:13px\">The code expires in {ttl_minutes} minutes and works once.<br>{footer}</p></div>"
    );
    Email {
        to: to.to_string(),
        subject: subject.to_string(),
        text,
        html,
        idempotency_key: format!("{}-{key}", purpose.as_str()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn payload_shape() {
        let m = LettermintMailer::new("https://x/v1/", "tok", "Easyshot <a@b.c>", Some("outbound"));
        let e = code_email(CodePurpose::LoginOtp, "u@e.com", "123456", 10, "k1");
        let p = m.payload(&e);
        assert_eq!(p["from"], "Easyshot <a@b.c>");
        assert_eq!(p["to"], json!(["u@e.com"]));
        assert_eq!(p["route"], "outbound");
        assert!(p["text"].as_str().unwrap().contains("123456"));
        assert!(p["html"].as_str().unwrap().contains("123456"));
        assert_eq!(e.idempotency_key, "login_otp-k1");
        assert_eq!(m.api_url, "https://x/v1");
        let m = LettermintMailer::new("https://x", "tok", "a@b.c", None);
        assert!(m.payload(&e).get("route").is_none());
    }
}
