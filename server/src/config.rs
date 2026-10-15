//! Environment-driven configuration.

#[derive(Debug, Clone)]
pub struct Config {
    /// App-role connection (`easyshot_app`, NOSUPERUSER NOBYPASSRLS).
    pub database_url: String,
    /// Owner-role connection for migrations; `RUN_MIGRATIONS` and `migrate` need it.
    pub migration_database_url: Option<String>,
    pub bind_addr: String,
    pub public_base_url: String,
    pub s3_bucket: String,
    pub s3_region: String,
    pub s3_endpoint: Option<String>,
    pub s3_force_path_style: bool,
    pub cron_secret: Option<String>,
    pub retention_days: i64,
    /// Users not seen for this many days are purged by the expire job; 0 disables.
    pub inactive_user_days: i64,
    pub max_upload_bytes: i64,
    pub allow_signups: bool,
    pub run_migrations: bool,
    pub db_max_connections: u32,
    /// Lettermint project token; email features are disabled when unset.
    pub lettermint_api_token: Option<String>,
    pub lettermint_api_url: String,
    pub lettermint_route: Option<String>,
    /// `From` header, e.g. `Name <sender@your-verified-domain>`. Required with the token.
    pub mail_from: Option<String>,
    /// Block creating uploads until the account's email is confirmed.
    pub require_email_verification: bool,
    pub auth_code_ttl_minutes: i64,
    /// Days a shared video stays available.
    pub video_retention_days: i64,
    /// Largest accepted recording, in bytes.
    pub max_video_bytes: i64,
    /// Key for password-unlock cookies and viewer hashes. Random per process when unset, so
    /// unlocks and same-day view dedupe reset on restart.
    pub web_secret: Option<String>,
    /// Reverse-proxy hops in front of the server that set `X-Forwarded-For` (1 on Fly.io).
    pub trusted_proxy_hops: usize,
    /// Where the landing page sends people to get the Mac app.
    pub download_url: String,
    /// Per-client-address budgets for sign-in, sign-up and emailed codes (web and API share them).
    pub auth_limits: AuthLimits,
}

/// `max` hits per `window_secs` for one client address.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Limit {
    pub max: u32,
    pub window_secs: u64,
}

/// Per-address auth budgets, applied before any password hashing or account creation.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AuthLimits {
    /// Password sign-ins (`POST /login`, `/v1/auth/login`).
    pub login: Limit,
    /// Sign-up attempts (`POST /signup`, `/v1/auth/register`), each of which may mail a code.
    pub signup: Limit,
    /// Requests that mail a code: sign-in codes, resends, password resets, verification.
    pub code_request: Limit,
    /// Code submissions: verification, sign-in codes, password resets.
    pub code_verify: Limit,
}

impl Default for AuthLimits {
    fn default() -> Self {
        let l = |max, window_secs| Limit { max, window_secs };
        AuthLimits {
            login: l(20, 600),
            signup: l(5, 3600),
            code_request: l(10, 600),
            code_verify: l(20, 600),
        }
    }
}

pub const DEFAULT_DOWNLOAD_URL: &str = "https://github.com/mscno/easyshot/releases/latest";

fn parse_bool(s: &str) -> Option<bool> {
    match s.trim().to_ascii_lowercase().as_str() {
        "true" | "1" | "yes" | "on" => Some(true),
        "false" | "0" | "no" | "off" => Some(false),
        _ => None,
    }
}

impl Config {
    pub fn from_env() -> Result<Self, String> {
        Self::from_lookup(|k| std::env::var(k).ok())
    }

    /// Build from an arbitrary key lookup (empty values count as unset).
    pub fn from_lookup<F: Fn(&str) -> Option<String>>(get: F) -> Result<Self, String> {
        let get = |k: &str| {
            get(k)
                .map(|v| v.trim().to_string())
                .filter(|v| !v.is_empty())
        };
        let boolean = |k: &str, default: bool| -> Result<bool, String> {
            match get(k) {
                None => Ok(default),
                Some(v) => parse_bool(&v).ok_or_else(|| format!("{k} must be a boolean")),
            }
        };
        let number = |k: &str, default: i64| -> Result<i64, String> {
            match get(k) {
                None => Ok(default),
                Some(v) => v
                    .parse::<i64>()
                    .ok()
                    .filter(|n| *n > 0)
                    .ok_or_else(|| format!("{k} must be a positive integer")),
            }
        };
        let non_negative = |k: &str, default: i64| -> Result<i64, String> {
            match get(k) {
                None => Ok(default),
                Some(v) => v
                    .parse::<i64>()
                    .ok()
                    .filter(|n| *n >= 0)
                    .ok_or_else(|| format!("{k} must be a non-negative integer")),
            }
        };
        Ok(Config {
            migration_database_url: get("MIGRATION_DATABASE_URL"),
            database_url: get("DATABASE_URL").ok_or("DATABASE_URL is required")?,
            bind_addr: get("BIND_ADDR").unwrap_or_else(|| "0.0.0.0:8080".into()),
            public_base_url: get("PUBLIC_BASE_URL")
                .unwrap_or_else(|| "http://localhost:8080".into())
                .trim_end_matches('/')
                .to_string(),
            s3_bucket: get("S3_BUCKET")
                .or_else(|| get("BUCKET_NAME"))
                .ok_or("S3_BUCKET (or BUCKET_NAME) is required")?,
            s3_region: get("S3_REGION")
                .or_else(|| get("AWS_REGION"))
                .unwrap_or_else(|| "us-east-1".into()),
            s3_endpoint: get("S3_ENDPOINT"),
            s3_force_path_style: boolean("S3_FORCE_PATH_STYLE", false)?,
            cron_secret: get("CRON_SECRET"),
            retention_days: number("RETENTION_DAYS", 30)?,
            inactive_user_days: non_negative("INACTIVE_USER_DAYS", 90)?,
            max_upload_bytes: number("MAX_UPLOAD_BYTES", 26_214_400)?,
            allow_signups: boolean("ALLOW_SIGNUPS", true)?,
            run_migrations: boolean("RUN_MIGRATIONS", false)?,
            db_max_connections: number("DB_MAX_CONNECTIONS", 5)? as u32,
            lettermint_api_token: get("LETTERMINT_API_TOKEN"),
            lettermint_api_url: get("LETTERMINT_API_URL")
                .unwrap_or_else(|| "https://api.lettermint.co/v1".into()),
            lettermint_route: Some(
                get("LETTERMINT_ROUTE").unwrap_or_else(|| "transactional".into()),
            ),
            mail_from: get("MAIL_FROM"),
            require_email_verification: boolean(
                "REQUIRE_EMAIL_VERIFICATION",
                get("LETTERMINT_API_TOKEN").is_some(),
            )?,
            auth_code_ttl_minutes: number("AUTH_CODE_TTL_MINUTES", 10)?,
            video_retention_days: number("VIDEO_RETENTION_DAYS", 90)?,
            max_video_bytes: number("MAX_VIDEO_BYTES", 5 * 1024 * 1024 * 1024)?,
            web_secret: get("WEB_SECRET"),
            trusted_proxy_hops: non_negative("TRUSTED_PROXY_HOPS", 0)? as usize,
            download_url: get("DOWNLOAD_URL").unwrap_or_else(|| DEFAULT_DOWNLOAD_URL.into()),
            auth_limits: AuthLimits::default(),
        })
        .and_then(|c| {
            if c.lettermint_api_token.is_some() && c.mail_from.is_none() {
                return Err("MAIL_FROM is required when LETTERMINT_API_TOKEN is set".into());
            }
            if c.require_email_verification && c.lettermint_api_token.is_none() {
                return Err(
                    "REQUIRE_EMAIL_VERIFICATION needs LETTERMINT_API_TOKEN to send codes".into(),
                );
            }
            Ok(c)
        })
    }

    /// A config suitable for tests.
    pub fn for_tests(database_url: &str) -> Self {
        Config {
            database_url: database_url.into(),
            migration_database_url: None,
            bind_addr: "127.0.0.1:0".into(),
            public_base_url: "http://localhost:8080".into(),
            s3_bucket: "test".into(),
            s3_region: "us-east-1".into(),
            s3_endpoint: None,
            s3_force_path_style: false,
            cron_secret: Some("cron-secret".into()),
            retention_days: 30,
            inactive_user_days: 90,
            max_upload_bytes: 26_214_400,
            allow_signups: true,
            run_migrations: false,
            db_max_connections: 5,
            lettermint_api_token: None,
            lettermint_api_url: "https://api.lettermint.co/v1".into(),
            lettermint_route: Some("transactional".into()),
            mail_from: None,
            require_email_verification: false,
            auth_code_ttl_minutes: 10,
            video_retention_days: 90,
            max_video_bytes: 5 * 1024 * 1024 * 1024,
            web_secret: Some("test-web-secret".into()),
            trusted_proxy_hops: 0,
            download_url: DEFAULT_DOWNLOAD_URL.into(),
            auth_limits: AuthLimits::default(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    fn lookup(pairs: &[(&str, &str)]) -> impl Fn(&str) -> Option<String> {
        let m: HashMap<String, String> = pairs
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect();
        move |k| m.get(k).cloned()
    }

    #[test]
    fn defaults() {
        let c = Config::from_lookup(lookup(&[
            ("DATABASE_URL", "postgres://x"),
            ("S3_BUCKET", "b"),
        ]))
        .unwrap();
        assert_eq!(c.bind_addr, "0.0.0.0:8080");
        assert_eq!(c.retention_days, 30);
        assert_eq!(c.inactive_user_days, 90);
        assert!(c.migration_database_url.is_none());
        assert_eq!(c.s3_region, "us-east-1");
        assert_eq!(c.max_upload_bytes, 26_214_400);
        assert!(c.allow_signups && !c.run_migrations && !c.s3_force_path_style);
        assert_eq!(c.db_max_connections, 5);
        assert!(c.cron_secret.is_none());
    }

    #[test]
    fn overrides_and_trim() {
        let c = Config::from_lookup(lookup(&[
            ("DATABASE_URL", "postgres://x"),
            ("S3_BUCKET", "b"),
            ("PUBLIC_BASE_URL", "https://s.example.com/"),
            ("S3_FORCE_PATH_STYLE", "true"),
            ("ALLOW_SIGNUPS", "false"),
            ("RETENTION_DAYS", "7"),
            ("CRON_SECRET", ""),
        ]))
        .unwrap();
        assert_eq!(c.public_base_url, "https://s.example.com");
        assert!(c.s3_force_path_style && !c.allow_signups);
        assert_eq!(c.retention_days, 7);
        assert!(c.cron_secret.is_none());
    }

    #[test]
    fn fly_tigris_fallbacks_and_inactive_days() {
        let c = Config::from_lookup(lookup(&[
            ("DATABASE_URL", "postgres://easyshot_app@db/x"),
            ("MIGRATION_DATABASE_URL", "postgres://owner@db/x"),
            ("BUCKET_NAME", "tigris-bucket"),
            ("AWS_REGION", "auto"),
            ("INACTIVE_USER_DAYS", "0"),
        ]))
        .unwrap();
        assert_eq!(c.s3_bucket, "tigris-bucket");
        assert_eq!(c.s3_region, "auto");
        assert_eq!(
            c.migration_database_url.as_deref(),
            Some("postgres://owner@db/x")
        );
        assert_eq!(c.inactive_user_days, 0);
        let c = Config::from_lookup(lookup(&[
            ("DATABASE_URL", "x"),
            ("S3_BUCKET", "a"),
            ("BUCKET_NAME", "b"),
            ("S3_REGION", "eu-west-1"),
            ("AWS_REGION", "auto"),
        ]))
        .unwrap();
        assert_eq!(
            (c.s3_bucket.as_str(), c.s3_region.as_str()),
            ("a", "eu-west-1")
        );
        assert!(
            Config::from_lookup(lookup(&[
                ("DATABASE_URL", "x"),
                ("S3_BUCKET", "b"),
                ("INACTIVE_USER_DAYS", "-1")
            ]))
            .is_err()
        );
    }

    #[test]
    fn mail_config() {
        let base = [("DATABASE_URL", "x"), ("S3_BUCKET", "b")];
        let with = |extra: &[(&str, &str)]| {
            let all: Vec<_> = base.iter().chain(extra.iter()).copied().collect();
            Config::from_lookup(lookup(&all))
        };
        let c = with(&[]).unwrap();
        assert!(c.lettermint_api_token.is_none() && !c.require_email_verification);
        assert_eq!(c.lettermint_route.as_deref(), Some("transactional"));
        assert_eq!(c.lettermint_api_url, "https://api.lettermint.co/v1");
        assert_eq!(c.auth_code_ttl_minutes, 10);
        assert!(with(&[("LETTERMINT_API_TOKEN", "t")]).is_err());
        let c = with(&[("LETTERMINT_API_TOKEN", "t"), ("MAIL_FROM", "a@b.c")]).unwrap();
        assert_eq!(c.mail_from.as_deref(), Some("a@b.c"));
        // verification is required by default once email is configured
        assert!(c.require_email_verification);
        let c = with(&[
            ("LETTERMINT_API_TOKEN", "t"),
            ("MAIL_FROM", "a@b.c"),
            ("REQUIRE_EMAIL_VERIFICATION", "false"),
        ])
        .unwrap();
        assert!(!c.require_email_verification);
        assert!(with(&[("REQUIRE_EMAIL_VERIFICATION", "true")]).is_err());
    }

    #[test]
    fn errors() {
        assert!(Config::from_lookup(lookup(&[])).is_err());
        assert!(
            Config::from_lookup(lookup(&[
                ("DATABASE_URL", "x"),
                ("S3_BUCKET", "b"),
                ("RETENTION_DAYS", "abc")
            ]))
            .is_err()
        );
        assert!(
            Config::from_lookup(lookup(&[
                ("DATABASE_URL", "x"),
                ("S3_BUCKET", "b"),
                ("ALLOW_SIGNUPS", "maybe")
            ]))
            .is_err()
        );
    }
}
