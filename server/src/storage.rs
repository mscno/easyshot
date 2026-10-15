//! Object storage abstraction, S3 implementation and an in-memory fake.

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::Duration;

use async_trait::async_trait;
use aws_sdk_s3::Client;
use aws_sdk_s3::config::{
    BehaviorVersion, Credentials, Region, RequestChecksumCalculation, ResponseChecksumValidation,
};
use aws_sdk_s3::presigning::PresigningConfig;
use aws_sdk_s3::types::{CompletedMultipartUpload, CompletedPart, Delete, ObjectIdentifier};

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

    /// Presigned GET with an explicit `Content-Disposition` (e.g. `attachment; filename=..`).
    async fn presign_get_with(
        &self,
        key: &str,
        ttl: Duration,
        content_type: &str,
        disposition: &str,
    ) -> StoreResult<String>;
    /// Small objects only (transcripts): `None` when missing, error when over `max` bytes.
    async fn get_bytes(&self, key: &str, max: usize) -> StoreResult<Option<Vec<u8>>>;

    // Multipart uploads: the client PUTs parts straight to presigned URLs while recording.
    async fn create_multipart(&self, key: &str, content_type: &str) -> StoreResult<String>;
    /// The part's exact byte length is signed into the URL (`Content-Length`), so the
    /// store rejects a body of any other size; send `headers` with the PUT.
    async fn presign_upload_part(
        &self,
        key: &str,
        upload_id: &str,
        part_number: i32,
        content_length: i64,
        ttl: Duration,
    ) -> StoreResult<PresignedPut>;
    /// `parts` are `(part_number, etag)` in ascending order.
    async fn complete_multipart(
        &self,
        key: &str,
        upload_id: &str,
        parts: &[(i32, String)],
    ) -> StoreResult<()>;
    /// Idempotent: aborting an unknown or finished upload succeeds.
    async fn abort_multipart(&self, key: &str, upload_id: &str) -> StoreResult<()>;
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

    async fn presign_get_with(
        &self,
        key: &str,
        ttl: Duration,
        content_type: &str,
        disposition: &str,
    ) -> StoreResult<String> {
        let req = self
            .client
            .get_object()
            .bucket(&self.bucket)
            .key(key)
            .response_content_type(content_type)
            .response_content_disposition(disposition)
            .presigned(PresigningConfig::expires_in(ttl).map_err(se)?)
            .await
            .map_err(se)?;
        Ok(req.uri().to_string())
    }

    async fn get_bytes(&self, key: &str, max: usize) -> StoreResult<Option<Vec<u8>>> {
        match self
            .client
            .get_object()
            .bucket(&self.bucket)
            .key(key)
            .send()
            .await
        {
            Ok(o) => {
                let too_big = || StoreError(format!("object larger than {max} bytes"));
                if o.content_length().unwrap_or(0) as usize > max {
                    return Err(too_big());
                }
                let bytes = o.body.collect().await.map_err(se)?.into_bytes();
                if bytes.len() > max {
                    return Err(too_big());
                }
                Ok(Some(bytes.to_vec()))
            }
            Err(e) => {
                if e.as_service_error()
                    .map(|s| s.is_no_such_key())
                    .unwrap_or(false)
                {
                    Ok(None)
                } else {
                    Err(se(aws_sdk_s3::error::DisplayErrorContext(&e)))
                }
            }
        }
    }

    async fn create_multipart(&self, key: &str, content_type: &str) -> StoreResult<String> {
        let out = self
            .client
            .create_multipart_upload()
            .bucket(&self.bucket)
            .key(key)
            .content_type(content_type)
            .send()
            .await
            .map_err(|e| se(aws_sdk_s3::error::DisplayErrorContext(&e)))?;
        out.upload_id()
            .map(str::to_string)
            .ok_or_else(|| StoreError("store returned no upload id".into()))
    }

    async fn presign_upload_part(
        &self,
        key: &str,
        upload_id: &str,
        part_number: i32,
        content_length: i64,
        ttl: Duration,
    ) -> StoreResult<PresignedPut> {
        let req = self
            .client
            .upload_part()
            .bucket(&self.bucket)
            .key(key)
            .upload_id(upload_id)
            .part_number(part_number)
            .content_length(content_length)
            .presigned(PresigningConfig::expires_in(ttl).map_err(se)?)
            .await
            .map_err(se)?;
        if !req.uri().contains("content-length") {
            // Unsigned, the URL would accept a body of any size.
            return Err(StoreError("part URL does not sign Content-Length".into()));
        }
        Ok(PresignedPut {
            url: req.uri().to_string(),
            headers: vec![("content-length".into(), content_length.to_string())],
        })
    }

    async fn complete_multipart(
        &self,
        key: &str,
        upload_id: &str,
        parts: &[(i32, String)],
    ) -> StoreResult<()> {
        let parts = parts
            .iter()
            .map(|(n, tag)| CompletedPart::builder().part_number(*n).e_tag(tag).build())
            .collect();
        self.client
            .complete_multipart_upload()
            .bucket(&self.bucket)
            .key(key)
            .upload_id(upload_id)
            .multipart_upload(
                CompletedMultipartUpload::builder()
                    .set_parts(Some(parts))
                    .build(),
            )
            .send()
            .await
            .map_err(|e| se(aws_sdk_s3::error::DisplayErrorContext(&e)))?;
        Ok(())
    }

    async fn abort_multipart(&self, key: &str, upload_id: &str) -> StoreResult<()> {
        match self
            .client
            .abort_multipart_upload()
            .bucket(&self.bucket)
            .key(key)
            .upload_id(upload_id)
            .send()
            .await
        {
            Ok(_) => Ok(()),
            Err(e) => {
                use aws_sdk_s3::error::ProvideErrorMetadata;
                if e.as_service_error().and_then(|s| s.code()) == Some("NoSuchUpload") {
                    Ok(())
                } else {
                    Err(se(aws_sdk_s3::error::DisplayErrorContext(&e)))
                }
            }
        }
    }
}

/// In-memory fake used by tests.
#[derive(Default)]
pub struct MemoryStore {
    objects: Mutex<HashMap<String, ObjectMeta>>,
    bytes: Mutex<HashMap<String, Vec<u8>>>,
    uploads: Mutex<HashMap<String, MemUpload>>,
    /// Content-Length signed into each part URL: (upload id, part number) -> bytes.
    signed: Mutex<HashMap<(String, i32), i64>>,
    fail_deletes: Mutex<bool>,
}

/// key, content type, part number -> (tag, size)
type MemUpload = (String, String, HashMap<i32, (String, i64)>);

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
    /// Simulate a client upload with content (readable through `get_bytes`).
    pub fn put_bytes(&self, key: &str, bytes: &[u8], content_type: &str) {
        self.put(key, bytes.len() as i64, content_type);
        self.bytes
            .lock()
            .unwrap()
            .insert(key.to_string(), bytes.to_vec());
    }
    /// Simulate a client uploading one part; returns its ETag. Panics where S3 would refuse
    /// the PUT (see [`try_put_part`](Self::try_put_part)).
    pub fn put_part(&self, upload_id: &str, part_number: i32, size: i64) -> String {
        self.try_put_part(upload_id, part_number, size)
            .unwrap_or_else(|e| panic!("{e}"))
    }
    /// Like S3: a body whose size differs from the Content-Length signed into the part's
    /// URL fails, as does a part for an unknown or finished upload.
    pub fn try_put_part(
        &self,
        upload_id: &str,
        part_number: i32,
        size: i64,
    ) -> StoreResult<String> {
        if let Some(signed) = self.signed_part_size(upload_id, part_number)
            && signed != size
        {
            return Err(StoreError(format!(
                "SignatureDoesNotMatch: part {part_number} signed for {signed} bytes, got {size}"
            )));
        }
        let tag = format!("\"tag-{upload_id}-{part_number}\"");
        self.uploads
            .lock()
            .unwrap()
            .get_mut(upload_id)
            .ok_or_else(|| StoreError("NoSuchUpload".into()))?
            .2
            .insert(part_number, (tag.clone(), size));
        Ok(tag)
    }
    /// The Content-Length the latest presigned URL for this part allows.
    pub fn signed_part_size(&self, upload_id: &str, part_number: i32) -> Option<i64> {
        self.signed
            .lock()
            .unwrap()
            .get(&(upload_id.to_string(), part_number))
            .copied()
    }
    pub fn open_uploads(&self) -> usize {
        self.uploads.lock().unwrap().len()
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
        let mut b = self.bytes.lock().unwrap();
        for k in keys {
            m.remove(k);
            b.remove(k);
        }
        Ok(())
    }
    async fn presign_get_with(
        &self,
        key: &str,
        ttl: Duration,
        content_type: &str,
        disposition: &str,
    ) -> StoreResult<String> {
        Ok(format!(
            "https://store.test/get/{key}?ttl={}&response-content-type={}&response-content-disposition={}",
            ttl.as_secs(),
            content_type.replace('/', "%2F"),
            disposition.split(';').next().unwrap_or("")
        ))
    }
    async fn get_bytes(&self, key: &str, max: usize) -> StoreResult<Option<Vec<u8>>> {
        match self.bytes.lock().unwrap().get(key) {
            Some(b) if b.len() > max => Err(StoreError("too large".into())),
            other => Ok(other.cloned()),
        }
    }
    async fn create_multipart(&self, key: &str, content_type: &str) -> StoreResult<String> {
        let id = format!("up-{}", uuid::Uuid::new_v4().simple());
        self.uploads.lock().unwrap().insert(
            id.clone(),
            (key.to_string(), content_type.to_string(), HashMap::new()),
        );
        Ok(id)
    }
    async fn presign_upload_part(
        &self,
        key: &str,
        upload_id: &str,
        part_number: i32,
        content_length: i64,
        ttl: Duration,
    ) -> StoreResult<PresignedPut> {
        self.signed
            .lock()
            .unwrap()
            .insert((upload_id.to_string(), part_number), content_length);
        Ok(PresignedPut {
            url: format!(
                "https://store.test/part/{key}?uploadId={upload_id}&partNumber={part_number}&len={content_length}&ttl={}",
                ttl.as_secs()
            ),
            headers: vec![("content-length".into(), content_length.to_string())],
        })
    }
    async fn complete_multipart(
        &self,
        key: &str,
        upload_id: &str,
        parts: &[(i32, String)],
    ) -> StoreResult<()> {
        let mut uploads = self.uploads.lock().unwrap();
        let (k, ct, stored) = uploads
            .get(upload_id)
            .ok_or_else(|| StoreError("NoSuchUpload".into()))?;
        if k != key || parts.is_empty() {
            return Err(StoreError("InvalidPart".into()));
        }
        let mut size = 0;
        for (n, tag) in parts {
            match stored.get(n) {
                Some((t, s)) if t == tag => size += s,
                _ => return Err(StoreError(format!("InvalidPart {n}"))),
            }
        }
        let ct = ct.clone();
        uploads.remove(upload_id);
        drop(uploads);
        self.put(key, size, &ct);
        Ok(())
    }
    async fn abort_multipart(&self, _key: &str, upload_id: &str) -> StoreResult<()> {
        self.uploads.lock().unwrap().remove(upload_id);
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
        // SAFETY: the only test in this binary that touches these variables.
        unsafe {
            std::env::set_var("AWS_ACCESS_KEY_ID", "tid_test");
            std::env::set_var("AWS_SECRET_ACCESS_KEY", "tsec_test");
            std::env::set_var("AWS_ENDPOINT_URL_S3", "https://fly.storage.tigris.dev");
        }

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
        // Part URLs sign the exact Content-Length.
        let part = store
            .presign_upload_part("k", "up1", 3, 5_242_880, Duration::from_secs(60))
            .await
            .unwrap();
        assert!(
            part.url
                .contains("X-Amz-SignedHeaders=content-length%3Bhost"),
            "{}",
            part.url
        );
        assert_eq!(
            part.headers,
            [("content-length".to_string(), "5242880".to_string())]
        );
        // SAFETY: see above.
        unsafe { std::env::remove_var("AWS_ENDPOINT_URL_S3") };
    }
}
