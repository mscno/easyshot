//! Static assets compiled into the binary and served from `/static/`. Application files are
//! referenced with a content-hash query (`?v=`) and cached immutably; the vendored Datastar
//! bundle has its version in the file name, because application modules import it by that
//! exact URL (one runtime instance per page).

use std::sync::LazyLock;

use sha2::{Digest, Sha256};
use topcoat::{
    Result,
    context::Cx,
    router::{
        Body, HeaderValue, StatusCode, error::not_found, header, path_param, request::headers,
        response::Response, route,
    },
};

/// Datastar v1.0.4 + Rocket beta.2, MIT (static/DATASTAR-LICENSE.md),
/// sha256 c723fb309157a555609df273e4693dcc4e193e68e6d7477f3285b955288e1e7b.
pub const DATASTAR: &str = "/static/datastar-rocket-1.0.4.js";

struct Asset {
    name: &'static str,
    content_type: &'static str,
    bytes: &'static [u8],
    etag: String,
    /// Versioned files never change under the same name.
    immutable_name: bool,
}

static ASSETS: LazyLock<Vec<Asset>> = LazyLock::new(|| {
    let files: [(&str, &str, &[u8], bool); 5] = [
        (
            "datastar-rocket-1.0.4.js",
            "text/javascript; charset=utf-8",
            include_bytes!("../../static/datastar-rocket-1.0.4.js"),
            true,
        ),
        (
            "DATASTAR-LICENSE.md",
            "text/markdown; charset=utf-8",
            include_bytes!("../../static/DATASTAR-LICENSE.md"),
            false,
        ),
        (
            "app.js",
            "text/javascript; charset=utf-8",
            include_bytes!("../../static/app.js"),
            false,
        ),
        (
            "app.css",
            "text/css; charset=utf-8",
            include_bytes!("../../static/app.css"),
            false,
        ),
        (
            "icon.svg",
            "image/svg+xml",
            include_bytes!("../../static/icon.svg"),
            false,
        ),
    ];
    files
        .into_iter()
        .map(|(name, content_type, bytes, immutable_name)| {
            let hash: String = Sha256::digest(bytes)[..8]
                .iter()
                .map(|b| format!("{b:02x}"))
                .collect();
            Asset {
                name,
                content_type,
                bytes,
                etag: format!("\"{hash}\""),
                immutable_name,
            }
        })
        .collect()
});

/// Cache-busting URL for an application asset.
pub fn url(name: &str) -> String {
    match ASSETS.iter().find(|a| a.name == name) {
        Some(a) if a.immutable_name => format!("/static/{}", a.name),
        Some(a) => format!("/static/{}?v={}", a.name, a.etag.trim_matches('"')),
        None => format!("/static/{name}"),
    }
}

path_param!(pub file);

#[route(GET "/static/{file}")]
pub async fn serve_static(cx: &Cx) -> Result<Response> {
    let name = path_param::<File>(cx);
    let asset = ASSETS
        .iter()
        .find(|a| a.name == name)
        .ok_or_else(not_found)?;
    let versioned = asset.immutable_name
        || topcoat::router::request::uri(cx)
            .query()
            .is_some_and(|q| q.contains(asset.etag.trim_matches('"')));
    let cache = if versioned {
        "public, max-age=31536000, immutable"
    } else {
        "public, max-age=300"
    };
    let matches = headers(cx)
        .get(header::IF_NONE_MATCH)
        .is_some_and(|v| v.as_bytes() == asset.etag.as_bytes());
    let mut res = if matches {
        let mut r = Response::new(Body::empty());
        *r.status_mut() = StatusCode::NOT_MODIFIED;
        r
    } else {
        Response::new(Body::from(asset.bytes))
    };
    let h = res.headers_mut();
    h.insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static(asset.content_type),
    );
    h.insert(header::CACHE_CONTROL, HeaderValue::from_static(cache));
    h.insert(
        header::ETAG,
        HeaderValue::from_str(&asset.etag).expect("etag"),
    );
    Ok(res)
}
