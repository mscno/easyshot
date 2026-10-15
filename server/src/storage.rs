//! Object storage abstraction, S3 implementation and an in-memory fake.

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::Duration;

use async_trait::async_trait;
use aws_sdk_s3::config::{
    BehaviorVersion, Credentials, Region, RequestChecksumCalculation, ResponseChecksumValidation,
};
use aws_sdk_s3::presigning::PresigningConfig;
use aws_sdk_s3::types::{Delete, ObjectIdentifier};
use aws_sdk_s3::Client;

use crate::config::Config;

#[derive(Debug, thiserror::Error)]
#[error("{0}")]
pub struct StoreError(pub String);

pub type StoreResult<T> = Result<T, StoreError>;

#[derive(Debug, Clone)]
pub struct PresignedPut {
    pub url: String,
    pub headers: Vec<(String, String)>,
}

#[derive(Debug, Clone)]
pub struct ObjectMeta {
    pub size: i64,
    pub content_type: Option<String>,
}

#[async_trait]
pub trait ObjectStore: Send + Sync {
    async fn presign_put(
        &self,
        key: &str,
        content_type: &str,
        content_length: i64,
        ttl: Duration,
    ) -> StoreResult<PresignedPut>;
    async fn presign_get(
        &self,
        key: &str,
        ttl: Duration,
        content_type: &str,
    ) -> StoreResult<String>;
    async fn head(&self, key: &str) -> StoreResult<Option<ObjectMeta>>;
    async fn delete_many(&self, keys: &[String]) -> StoreResult<()>;
}

pub struct S3Store {
    client: Client,
    bucket: String,
}

impl S3Store {
    pub async fn from_config(cfg: &Config) -> Self {
        let shared = aws_config::defaults(BehaviorVersion::latest())
            .region(Region::new(cfg.s3_region.clone()))
            .load()
            .await;
        let mut b = aws_sdk_s3::config::Builder::from(&shared)
            .force_path_style(cfg.s3_force_path_style)
            // Presigned PUTs from plain HTTP clients cannot carry the SDK's default CRC checksums.
            .request_checksum_calculation(RequestChecksumCalculation::WhenRequired)
            .response_checksum_validation(ResponseChecksumValidation::WhenRequired);
        if let Some(ep) = &cfg.s3_endpoint {
            b = b.endpoint_url(ep);
            // Custom endpoints (MinIO/R2) with no ambient credentials: fail at request time, not here.
            if shared.credentials_provider().is_none() {
                b = b.credentials_provider(Credentials::new(
                    "minioadmin",
                    "minioadmin",
                    None,
                    None,
                    "fallback",
                ));
            }
        }
        Self {
            client: Client::from_conf(b.build()),
            bucket: cfg.s3_bucket.clone(),
        }
    }
}

fn se<E: std::fmt::Display>(e: E) -> StoreError {
    StoreError(e.to_string())
}

#[async_trait]
impl ObjectStore for S3Store {
    async fn presign_put(
        &self,
        key: &str,
        content_type: &str,
        content_length: i64,
        ttl: Duration,
    ) -> StoreResult<PresignedPut> {
        let req = self
            .client
            .put_object()
            .bucket(&self.bucket)
            .key(key)
            .content_type(content_type)
            .content_length(content_length)
            .presigned(PresigningConfig::expires_in(ttl).map_err(se)?)
            .await
            .map_err(se)?;
        Ok(PresignedPut {
            url: req.uri().to_string(),
            headers: vec![("Content-Type".into(), content_type.into())],
        })
    }

    async fn presign_get(
        &self,
        key: &str,
        ttl: Duration,
        content_type: &str,
    ) -> StoreResult<String> {
        let req = self
            .client
            .get_object()
            .bucket(&self.bucket)
            .key(key)
            .response_content_type(content_type)
            .response_content_disposition("inline")
            .presigned(PresigningConfig::expires_in(ttl).map_err(se)?)
            .await
            .map_err(se)?;
        Ok(req.uri().to_string())
    }

    async fn head(&self, key: &str) -> StoreResult<Option<ObjectMeta>> {
        match self
            .client
            .head_object()
            .bucket(&self.bucket)
            .key(key)
            .send()
            .await
        {
            Ok(o) => Ok(Some(ObjectMeta {
                size: o.content_length().unwrap_or(0),
                content_type: o.content_type().map(str::to_string),
            })),
            Err(e) => {
                if e.as_service_error()
                    .map(|s| s.is_not_found())
                    .unwrap_or(false)
                {
                    Ok(None)
                } else {
                    Err(se(aws_sdk_s3::error::DisplayErrorContext(&e)))
                }
            }
        }
    }

    async fn delete_many(&self, keys: &[String]) -> StoreResult<()> {
        for chunk in keys.chunks(1000) {
            let ids = chunk
                .iter()
                .map(|k| ObjectIdentifier::builder().key(k).build().map_err(se))
                .collect::<StoreResult<Vec<_>>>()?;
            let del = Delete::builder()
                .set_objects(Some(ids))
                .quiet(true)
                .build()
                .map_err(se)?;
            let out = self
                .client
                .delete_objects()
                .bucket(&self.bucket)
                .delete(del)
                .send()
                .await
                .map_err(|e| se(aws_sdk_s3::error::DisplayErrorContext(&e)))?;
            if let Some(first) = out.errors().first() {
                return Err(StoreError(format!(
                    "failed to delete {} object(s); first: {:?} {:?}",
                    out.errors().len(),
                    first.key(),
                    first.message()
                )));
            }
        }
        Ok(())
    }
}

/// In-memory fake used by tests.
#[derive(Default)]
pub struct MemoryStore {
    objects: Mutex<HashMap<String, ObjectMeta>>,
    fail_deletes: Mutex<bool>,
}

impl MemoryStore {
    pub fn new() -> Self {
        Self::default()
    }
    /// Simulate a client upload.
    pub fn put(&self, key: &str, size: i64, content_type: &str) {
        self.objects.lock().unwrap().insert(
            key.to_string(),
            ObjectMeta {
                size,
                content_type: Some(content_type.to_string()),
            },
        );
    }
    pub fn contains(&self, key: &str) -> bool {
        self.objects.lock().unwrap().contains_key(key)
    }
    pub fn len(&self) -> usize {
        self.objects.lock().unwrap().len()
    }
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
    pub fn keys(&self) -> Vec<String> {
        self.objects.lock().unwrap().keys().cloned().collect()
    }
    pub fn set_fail_deletes(&self, v: bool) {
        *self.fail_deletes.lock().unwrap() = v;
    }
}

#[async_trait]
impl ObjectStore for MemoryStore {
    async fn presign_put(
        &self,
        key: &str,
        content_type: &str,
        content_length: i64,
        ttl: Duration,
    ) -> StoreResult<PresignedPut> {
        Ok(PresignedPut {
            url: format!(
                "https://store.test/put/{key}?len={content_length}&ttl={}",
                ttl.as_secs()
            ),
            headers: vec![("Content-Type".into(), content_type.into())],
        })
    }
    async fn presign_get(
        &self,
        key: &str,
        ttl: Duration,
        content_type: &str,
    ) -> StoreResult<String> {
        Ok(format!(
            "https://store.test/get/{key}?ttl={}&response-content-type={}&response-content-disposition=inline",
            ttl.as_secs(),
            content_type.replace('/', "%2F")
        ))
    }
    async fn head(&self, key: &str) -> StoreResult<Option<ObjectMeta>> {
        Ok(self.objects.lock().unwrap().get(key).cloned())
    }
    async fn delete_many(&self, keys: &[String]) -> StoreResult<()> {
        if *self.fail_deletes.lock().unwrap() {
            return Err(StoreError("simulated failure".into()));
        }
        let mut m = self.objects.lock().unwrap();
        for k in keys {
            m.remove(k);
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cfg(endpoint: Option<&str>, force_path: bool) -> Config {
        let mut c = Config::for_tests("file::memory:");
        c.s3_bucket = "my-bucket".into();
        c.s3_region = "auto".into();
        c.s3_endpoint = endpoint.map(str::to_string);
        c.s3_force_path_style = force_path;
        c
    }

    /// Tigris on Fly: region "auto", endpoint from AWS_ENDPOINT_URL_S3, virtual-hosted URLs.
    /// (Env vars are process-global, so everything env-dependent lives in this one test.)
    #[tokio::test]
    async fn presigned_urls_for_tigris_style_config() {
        std::env::set_var("AWS_ACCESS_KEY_ID", "tid_test");
        std::env::set_var("AWS_SECRET_ACCESS_KEY", "tsec_test");
        std::env::set_var("AWS_ENDPOINT_URL_S3", "https://fly.storage.tigris.dev");

        let store = S3Store::from_config(&cfg(None, false)).await;
        let put = store
            .presign_put("u/x/1.png", "image/png", 10, Duration::from_secs(600))
            .await
            .unwrap();
        assert!(
            put.url
                .starts_with("https://my-bucket.fly.storage.tigris.dev/u/x/1.png?"),
            "{}",
            put.url
        );
        assert!(
            put.url.contains("%2Fauto%2Fs3%2Faws4_request"),
            "{}",
            put.url
        );
        let get = store
            .presign_get("u/x/1.png", Duration::from_secs(60), "image/png")
            .await
            .unwrap();
        assert!(get.starts_with("https://my-bucket.fly.storage.tigris.dev/u/x/1.png?"));

        // explicit S3_ENDPOINT wins; path style only when asked for
        let store = S3Store::from_config(&cfg(Some("http://127.0.0.1:9000"), true)).await;
        let get = store
            .presign_get("k", Duration::from_secs(60), "image/png")
            .await
            .unwrap();
        assert!(
            get.starts_with("http://127.0.0.1:9000/my-bucket/k?"),
            "{get}"
        );
        std::env::remove_var("AWS_ENDPOINT_URL_S3");
    }
}
