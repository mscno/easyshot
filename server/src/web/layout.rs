//! Page shell and small formatting helpers shared by the pages.

use std::future::Future;

use topcoat::{
    Result,
    view::{Child, View, component, view},
};

use super::assets;

/// Per-page `<head>` content.
#[derive(Debug, Clone, Default)]
pub struct Meta {
    pub title: String,
    pub description: Option<String>,
    /// `(property, content)` pairs for Open Graph / Twitter tags.
    pub og: Vec<(&'static str, String)>,
    pub oembed: Option<String>,
    pub canonical: Option<String>,
    /// Hide from search engines (share pages are unlisted).
    pub noindex: bool,
}

impl Meta {
    pub fn titled(title: impl Into<String>) -> Meta {
        Meta {
            title: title.into(),
            ..Meta::default()
        }
    }
}

#[component]
pub async fn shell(
    meta: Meta,
    signed_in: bool,
    #[default] bare: bool,
    child: Child<'_>,
) -> Result<impl View> {
    let title = if meta.title == "Easyshot" {
        meta.title.clone()
    } else {
        format!("{} · Easyshot", meta.title)
    };
    Ok(view! {
        <!DOCTYPE html>
        <html lang="en">
            <head>
                <meta charset="utf-8">
                <meta name="viewport" content="width=device-width, initial-scale=1">
                <meta name="color-scheme" content="light dark">
                <title>(title)</title>
                if let Some(d) = meta.description.as_deref() {
                    <meta name="description" content=(d)>
                }
                if meta.noindex {
                    <meta name="robots" content="noindex">
                }
                if let Some(c) = meta.canonical.as_deref() {
                    <link rel="canonical" href=(c)>
                }
                for (p, c) in meta.og.iter() {
                    <meta property=(*p) content=(c.as_str())>
                }
                if let Some(o) = meta.oembed.as_deref() {
                    <link rel="alternate" type="application/json+oembed" href=(o)>
                }
                <link rel="icon" href=(assets::url("icon.svg")) type="image/svg+xml">
                <link rel="stylesheet" href=(assets::url("app.css"))>
                <script type="module" src=(assets::DATASTAR)></script>
                <script type="module" src=(assets::url("app.js"))></script>
            </head>
            <body class=(if bare { "bare" } else { "" })>
                if !bare {
                    <header class="topbar">
                        <a class="brand" href="/">
                            <img
                                src=(assets::url("icon.svg"))
                                alt=""
                                width="28"
                                height="28"
                            >
                            <span>"Easyshot"</span>
                        </a>
                        <nav>
                            if signed_in {
                                <a href="/library">"Library"</a>
                                <a href="/account">"Account"</a>
                                <form method="post" action="/logout" class="inline">
                                    <button type="submit" class="link">"Sign out"</button>
                                </form>
                            } else {
                                <a href="/login">"Sign in"</a>
                                <a class="button small primary" href="/signup">
                                    "Sign up"
                                </a>
                            }
                        </nav>
                    </header>
                }
                <main id="main">(child)</main>
                // Target for the live streams' "your session ended" redirect.
                <div id="live-redirect" hidden=""></div>
                if !bare {
                    <footer class="footer">
                        <span>"Easyshot · recorded and encoded on your Mac"</span>
                        <a href="/static/DATASTAR-LICENSE.md">"Licenses"</a>
                    </footer>
                }
            </body>
        </html>
    })
}

/// `1:05` / `1:02:03` for a millisecond position.
pub fn clock(ms: i64) -> String {
    let s = ms.max(0) / 1000;
    let (h, m, s) = (s / 3600, (s % 3600) / 60, s % 60);
    if h > 0 {
        format!("{h}:{m:02}:{s:02}")
    } else {
        format!("{m}:{s:02}")
    }
}

/// "just now", "5 minutes ago", "3 days ago", or a date for older items.
pub fn ago(ms: i64, now: i64) -> String {
    let s = ((now - ms) / 1000).max(0);
    let plural = |n: i64, unit: &str| format!("{n} {unit}{} ago", if n == 1 { "" } else { "s" });
    match s {
        0..=44 => "just now".into(),
        45..=3_599 => plural((s / 60).max(1), "minute"),
        3_600..=86_399 => plural(s / 3600, "hour"),
        86_400..=2_591_999 => plural(s / 86_400, "day"),
        _ => crate::repo::ts(ms).format("%b %-d, %Y").to_string(),
    }
}

pub fn plural(n: i64, one: &str, many: &str) -> String {
    format!("{n} {}", if n == 1 { one } else { many })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn formats() {
        assert_eq!(clock(65_000), "1:05");
        assert_eq!(clock(3_723_000), "1:02:03");
        assert_eq!(ago(1000, 1000), "just now");
        assert_eq!(ago(0, 120_000), "2 minutes ago");
        assert_eq!(ago(0, 3_600_000), "1 hour ago");
        assert_eq!(ago(0, 3 * 86_400_000), "3 days ago");
        assert_eq!(plural(1, "view", "views"), "1 view");
    }
}
