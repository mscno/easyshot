//! The share page (`/v/{slug}`): player, transcript, timestamped comments and reactions,
//! kept live for every viewer through one Datastar SSE stream per page. Media, thumbnails
//! and downloads redirect to short-lived presigned URLs; bytes never pass through here.

use std::future::Future;
use std::time::{Duration, Instant};

use futures_util::{Stream, stream};
use serde::Deserialize;
use topcoat::{
    Result,
    context::Cx,
    cookie::{Cookies, SameSite, cookie, time},
    datastar::{ElementPatchMode, PatchElements, datastar_request},
    router::{
        Body, HeaderValue, StatusCode,
        content::{
            Form,
            sse::{Event, KeepAlive, Sse},
        },
        error::{not_found, see_other},
        header, page, path_param, query_params,
        response::{IntoResponse, Response},
        route,
    },
    view::{View, ViewExt, component, view},
};

use super::layout::{Meta, ago, clock, plural, shell};
use super::{Member, WebResult, csp, fingerprint, limit, member, scope_of, state};
use crate::repo::{self, now_ms};
use crate::state::AppState;
use crate::video::live::{Change, Hub, StreamSlot, Subscription, next_ping, try_ping};
use crate::video::model::{Comment, Reaction, Video};
use crate::video::scope::{Access, Scope, Visibility};
use crate::video::service::{self, Author, MEDIA_URL_TTL, SHORT_URL_TTL};

path_param!(pub slug);

/// Everything a request on a share link needs, with access already decided.
struct Viewing {
    member: Option<Member>,
    scope: Scope,
    video: Video,
    access: Access,
}

fn unlock_jar(cx: &Cx) -> impl Cookies {
    topcoat::cookie::cookies(cx).override_prefix_host()
}

async fn load(cx: &Cx) -> Result<Viewing> {
    let st = state(cx);
    let member = member(cx).await?;
    let scope = scope_of(&member);
    let slug = path_param::<Slug>(cx);
    let video = service::resolve_share_link(st, &scope, slug)
        .await
        .web()?
        .ok_or_else(not_found)?;
    let cookie = unlock_jar(cx).get(&service::unlock_cookie_name(&video));
    let unlocked = service::check_unlock(st, &video, cookie.as_ref().map(|c| c.value()));
    let access = scope.access(&video, unlocked);
    Ok(Viewing {
        member,
        scope,
        video,
        access,
    })
}

/// Like [`load`], but only for viewers who may watch.
async fn load_allowed(cx: &Cx) -> Result<Viewing> {
    let v = load(cx).await?;
    if v.access != Access::Allowed {
        return Err(not_found().into());
    }
    Ok(v)
}

fn thumb_url(v: &Video) -> String {
    format!("/v/{}/thumbnail.jpg", v.slug)
}

// ---------- page ----------

#[page("/v/{slug}")]
pub async fn watch(cx: &Cx) -> Result<impl View> {
    let st = state(cx);
    let w = load(cx).await?;
    let signed_in = w.member.is_some();
    let v = w.video;
    let data = match w.access {
        Access::Denied => return Err(not_found().into()),
        Access::NeedsPassword => None,
        Access::Allowed => {
            let (ip, ua) = fingerprint(cx);
            service::record_view(st, &w.scope, &v, &format!("{ip}|{ua}"))
                .await
                .web()?;
            Some(Snapshot::load(st, &w.scope, &v).await.web()?)
        }
    };
    let Some(data) = data else {
        return Ok(view! {
            shell(
                meta: Meta { noindex: true, ..Meta::titled("Password required") },
                signed_in: signed_in,
                password_gate(slug: v.slug.clone(), error: None)
            )
        }
        .boxed());
    };
    let base = st.config.public_base_url.clone();
    let url = format!("{base}/v/{}", v.slug);
    let public = Visibility::parse(&v.visibility) == Some(Visibility::Link);
    let mut og = vec![
        ("og:type", "video.other".to_string()),
        ("og:title", v.title.clone()),
        ("og:url", url.clone()),
        ("og:site_name", "Easyshot".to_string()),
        ("twitter:title", v.title.clone()),
    ];
    if public && v.thumbnail_key.is_some() {
        og.push(("og:image", format!("{base}{}", thumb_url(&v))));
        og.push(("twitter:card", "player".to_string()));
        og.push(("twitter:image", format!("{base}{}", thumb_url(&v))));
        og.push(("twitter:player", format!("{base}/v/{}/embed", v.slug)));
        og.push(("twitter:player:width", v.width.unwrap_or(1280).to_string()));
        og.push(("twitter:player:height", v.height.unwrap_or(720).to_string()));
    }
    let meta = Meta {
        title: v.title.clone(),
        description: Some(format!("Recording shared by {}", data.owner)),
        og,
        oembed: public.then(|| {
            format!(
                "{base}/oembed?format=json&url={}",
                url.replace(':', "%3A").replace('/', "%2F")
            )
        }),
        canonical: Some(url.clone()),
        noindex: true,
    };
    let member_name = w.member.as_ref().map(|m| m.name().to_string());
    let live_expr = format!(
        "@get('/v/{}/live?since={}', {{retry: 'always', retryMaxCount: 1000}})",
        v.slug,
        now_ms()
    );
    let now = now_ms();
    let has_transcript = v.transcript_key.is_some();
    Ok(view! {
        shell(
            meta: meta,
            signed_in: signed_in,
            <div id="watch" class="watch" data-init=(live_expr.as_str())>
                <div class="watch-main">
                    player_region(
                        video: v.clone(),
                        comments: data.comments.clone(),
                        reactions: data.markers.clone()
                    )
                    head_region(
                        video: v.clone(),
                        owner: data.owner.clone(),
                        views: data.views,
                        now: now,
                        url: url.clone()
                    )
                    reactions_region(slug: v.slug.clone(), totals: data.totals.clone())
                    <p id="live-notice" class="notice" role="status" hidden=""></p>
                </div>
                <aside class="watch-side">
                    transcript_region(available: has_transcript)
                    <section class="card comments-card" id="comments-card">
                        <h2>"Comments"</h2>
                        comments_region(comments: data.comments.clone(), now: now)
                        comment_form(
                            slug: v.slug.clone(),
                            member_name: member_name,
                            error: None
                        )
                    </section>
                </aside>
            </div>
        )
    }
    .boxed())
}

/// Data shown on the page and refreshed by the live stream.
struct Snapshot {
    owner: String,
    views: i64,
    comments: Vec<Comment>,
    totals: Vec<(&'static str, i64)>,
    markers: Vec<Reaction>,
}

impl Snapshot {
    async fn load(st: &AppState, scope: &Scope, v: &Video) -> crate::error::AppResult<Snapshot> {
        let (owner, views, comments, reactions) = tokio::try_join!(
            owner_name(st, v),
            view_count(st, scope, v),
            service::comments(st, scope, v),
            service::reactions(st, scope, v),
        )?;
        Ok(Snapshot {
            owner,
            views,
            comments,
            totals: reactions.0,
            markers: reactions.1,
        })
    }
}

async fn view_count(st: &AppState, scope: &Scope, v: &Video) -> crate::error::AppResult<i64> {
    Ok(service::view_counts(st, scope.share(v), &[v.id.as_str()])
        .await?
        .get(&v.id)
        .copied()
        .unwrap_or(0))
}

async fn owner_name(st: &AppState, v: &Video) -> crate::error::AppResult<String> {
    Ok(repo::user_email(&st.db, &v.user_id)
        .await?
        .map(|e| e.split('@').next().unwrap_or("").to_string())
        .unwrap_or_else(|| "Someone".into()))
}

// ---------- regions (stable ids; rendered on the page and patched over SSE) ----------

#[component]
pub async fn head_region(
    video: Video,
    owner: String,
    views: i64,
    now: i64,
    url: String,
) -> Result<impl View> {
    let v = video;
    let download_url = format!("/v/{}/download", v.slug);
    Ok(view! {
        <header id="video-head" class="video-head">
            <h1>(v.title.as_str())</h1>
            <p class="muted">
                <strong>(owner.as_str())</strong>
                " · "
                (ago(v.created_at, now))
                " · "
                (plural(views, "view", "views"))
                if v.duration_ms > 0 {
                    " · "
                    (clock(v.duration_ms))
                }
            </p>
            <div class="row">
                <button type="button" class="button small" data-copy=(url.as_str())>
                    "Copy link"
                </button>
                if v.status == "ready" {
                    <a class="button small" href=(download_url.as_str())>"Download"</a>
                }
            </div>
        </header>
    })
}

#[component]
pub async fn player_region(
    video: Video,
    comments: Vec<Comment>,
    reactions: Vec<Reaction>,
) -> Result<impl View> {
    let v = video;
    let media_url = format!("/v/{}/media", v.slug);
    let track_url = format!("/v/{}/transcript.vtt", v.slug);
    let poster = v.thumbnail_key.is_some().then(|| thumb_url(&v));
    let captions = v.transcript_key.is_some().then(|| track_url.clone());
    let ready = v.status == "ready";
    // The <video> keeps its playback across live patches (data-ignore-morph), so a poster
    // or transcript published later reaches it through the host's data-poster and
    // data-captions attributes, which <easyshot-player> applies (static/app.js).
    Ok(view! {
        <section id="player-region" class="player-region">
            if ready {
                <easyshot-player
                    id="player"
                    class="player"
                    data-poster=(poster.as_deref())
                    data-captions=(captions.as_deref())
                >
                    <video
                        id="video"
                        controls=""
                        playsinline=""
                        preload="metadata"
                        poster=(poster.as_deref())
                        data-ignore-morph=""
                    >
                        <source src=(media_url.as_str()) type=(v.content_type.as_str())>
                        if v.transcript_key.is_some() {
                            <track
                                kind="captions"
                                src=(track_url.as_str())
                                srclang="en"
                                label="Transcript"
                            >
                        }
                        <a href=(media_url.as_str())>"Download the video"</a>
                    </video>
                    markers_region(
                        duration_ms: v.duration_ms,
                        comments: comments,
                        reactions: reactions
                    )
                </easyshot-player>
            } else {
                <div class="processing">
                    <div class="spinner" aria-hidden="true"></div>
                    <p><strong>(upload_status(&v))</strong></p>
                    <p class="muted">
                        "This page updates by itself when the recording is ready."
                    </p>
                </div>
            }
        </section>
    })
}

/// Always on the page, hidden without a transcript, so one published later appears live.
/// `<easyshot-player>` fills the list from the captions track; the list is client-owned
/// (`data-ignore-morph`), so live patches show or hide the card without clearing it.
#[component]
pub async fn transcript_region(available: bool) -> Result<impl View> {
    Ok(view! {
        <section id="transcript-card" class="card transcript-card" hidden=(!available)>
            <h2>"Transcript"</h2>
            <ol
                id="transcript"
                class="transcript"
                data-transcript=""
                data-ignore-morph=""
            >
                <li class="muted">"Loading transcript…"</li>
            </ol>
        </section>
    })
}

/// What a pending recording is doing, from the app's progress reports.
pub fn upload_status(v: &Video) -> String {
    let mb = |b: i64| format!("{:.1} MB", b as f64 / 1_048_576.0);
    match (v.recording_ended_at, v.uploaded_bytes) {
        (None, 0) => "Recording live…".into(),
        (None, b) => format!("Recording live… {} uploaded", mb(b)),
        (Some(_), 0) => "Finishing…".into(),
        (Some(_), b) => format!("Finishing… {} uploaded", mb(b)),
    }
}

/// Comment and reaction positions along the timeline; buttons seek the player.
#[component]
pub async fn markers_region(
    duration_ms: i64,
    comments: Vec<Comment>,
    reactions: Vec<Reaction>,
) -> Result<impl View> {
    // `data-style:left` sets the position through CSSOM (inline style attributes are
    // blocked by the CSP); the value is a server-computed percentage, never user input.
    let pos = move |t: i64| {
        format!(
            "'{:.3}%'",
            (t.clamp(0, duration_ms) as f64 / duration_ms.max(1) as f64) * 100.0
        )
    };
    let comment_marks: Vec<(String, String, String)> = comments
        .iter()
        .filter_map(|c| {
            c.timestamp_ms.map(|t| {
                (
                    t.to_string(),
                    pos(t),
                    format!("{} at {}", c.author_name, clock(t)),
                )
            })
        })
        .collect();
    let reaction_marks: Vec<(String, String, String)> = reactions
        .iter()
        .filter_map(|r| {
            r.timestamp_ms
                .map(|t| (t.to_string(), pos(t), r.emoji.clone()))
        })
        .collect();
    let show = duration_ms > 0;
    Ok(view! {
        <div id="markers" class="markers" aria-label="Timeline markers">
            if show {
                for (t, left, label) in comment_marks {
                    <button
                        type="button"
                        class="marker comment"
                        data-seek-ms=(t.as_str())
                        data-style:left=(left.as_str())
                        title=(label.as_str())
                        aria-label=(label.as_str())
                    ></button>
                }
                for (t, left, emoji) in reaction_marks {
                    <button
                        type="button"
                        class="marker emoji"
                        data-seek-ms=(t.as_str())
                        data-style:left=(left.as_str())
                        aria-label=(emoji.as_str())
                    >
                        (emoji.as_str())
                    </button>
                }
            }
        </div>
    })
}

#[component]
pub async fn reactions_region(slug: String, totals: Vec<(&'static str, i64)>) -> Result<impl View> {
    let action = format!("/v/{slug}/reactions");
    let enhance =
        format!("@post('{action}', {{contentType: 'form', retry: 'never', retryMaxCount: 0}})");
    Ok(view! {
        <form
            id="reactions"
            class="reactions"
            method="post"
            action=(action.as_str())
            data-on:submit=(enhance.as_str())
        >
            <input type="hidden" name="timestamp_ms" value="" data-player-time="">
            for (emoji, n) in totals {
                <button
                    type="submit"
                    name="emoji"
                    value=(emoji)
                    class="reaction"
                    aria-label=(format!("React {emoji}"))
                >
                    <span>(emoji)</span>
                    if n > 0 {
                        <span class="count">(n)</span>
                    }
                </button>
            }
        </form>
    })
}

#[component]
pub async fn comments_region(comments: Vec<Comment>, now: i64) -> Result<impl View> {
    let empty = comments.is_empty();
    Ok(view! {
        <ol id="comments" class="comments" aria-live="polite">
            if empty {
                <li class="muted empty-comments">
                    "No comments yet. Pause anywhere and leave one."
                </li>
            }
            #[key(c.id.clone())]
            for c in comments {
                <li class="comment" id=(format!("c-{}", c.id))>
                    <div class="comment-head">
                        <strong>(c.author_name.as_str())</strong>
                        if c.user_id.is_some() {
                            <span class="pill">"member"</span>
                        } else {
                            <span class="pill guest">"guest"</span>
                        }
                        match c.timestamp_ms {
                            Some(t) => <button
                                type="button"
                                class="stamp"
                                data-seek-ms=(t.to_string())
                            >
                                (clock(t))
                            </button>,
                            None => "",
                        }
                        <span class="muted small">(ago(c.created_at, now))</span>
                    </div>
                    <p class="comment-body">(c.body.as_str())</p>
                </li>
            }
        </ol>
    })
}

#[component]
pub async fn comment_form(
    slug: String,
    member_name: Option<String>,
    error: Option<String>,
) -> Result<impl View> {
    let action = format!("/v/{slug}/comments");
    let enhance =
        format!("@post('{action}', {{contentType: 'form', retry: 'never', retryMaxCount: 0}})");
    Ok(view! {
        <form
            id="comment-form"
            class="stack comment-form"
            method="post"
            action=(action.as_str())
            data-on:submit=(enhance.as_str())
            data-indicator:_comment-sending=""
        >
            match error {
                Some(e) => <p class="notice error" role="alert">(e)</p>,
                None => "",
            }
            match member_name {
                Some(name) => <p class="muted small">
                    "Commenting as "
                    <strong>(name)</strong>
                </p>,
                None => {
                    <label for="comment-name">"Your name"</label>
                    <input
                        id="comment-name"
                        name="name"
                        maxlength="60"
                        autocomplete="name"
                        placeholder="Guest"
                    >
                }
            }
            <label for="comment-body" class="sr-only">"Comment"</label>
            <textarea
                id="comment-body"
                name="body"
                rows="3"
                maxlength="2000"
                required=""
                placeholder="Add a comment…"
            ></textarea>
            <div class="row between">
                <label class="check">
                    <input type="checkbox" name="at_time" value="1" checked="">
                    " at "
                    <span data-player-clock="">"0:00"</span>
                </label>
                <input type="hidden" name="timestamp_ms" value="" data-player-time="">
                <button
                    type="submit"
                    class="button primary small"
                    data-attr:disabled="$_commentSending"
                >
                    "Comment"
                </button>
            </div>
        </form>
    })
}

#[component]
async fn password_gate(slug: String, error: Option<String>) -> Result<impl View> {
    let action = format!("/v/{slug}/unlock");
    Ok(view! {
        <section class="card narrow">
            <h1>"This recording is password protected"</h1>
            match error {
                Some(e) => <p class="notice error" role="alert">(e)</p>,
                None => "",
            }
            <form method="post" action=(action.as_str()) class="stack">
                <label for="password">"Password"</label>
                <input
                    id="password"
                    name="password"
                    type="password"
                    required=""
                    autofocus=""
                    autocomplete="current-password"
                >
                <button type="submit" class="button primary">"Watch"</button>
            </form>
        </section>
    })
}

// ---------- embed ----------

#[page("/v/{slug}/embed")]
pub async fn embed(cx: &Cx) -> Result<impl View> {
    let w = load(cx).await?;
    // Only public links embed; other visibilities would leak through third-party frames.
    if w.access != Access::Allowed
        || Visibility::parse(&w.video.visibility) != Some(Visibility::Link)
    {
        return Err(not_found().into());
    }
    let st = state(cx);
    let data = Snapshot::load(st, &w.scope, &w.video).await.web()?;
    let v = w.video;
    let store = st.config.s3_endpoint.clone().unwrap_or_default();
    let origins = if store.starts_with("http://") {
        format!("https: {store}")
    } else {
        "https:".into()
    };
    // Embeds are framed by other sites (oEmbed), so this page allows any ancestor.
    let mut headers = topcoat::router::HeaderMap::new();
    headers.insert(header::CONTENT_SECURITY_POLICY, csp(&origins, "*"));
    let title = v.title.clone();
    Ok(view! {
        (headers)
        shell(
            meta: Meta { noindex: true, ..Meta::titled(title) },
            signed_in: false,
            bare: true,
            player_region(
                video: v.clone(),
                comments: data.comments,
                reactions: data.markers
            )
        )
    })
}

// ---------- password unlock ----------

#[derive(Deserialize)]
pub struct UnlockForm {
    password: String,
}

#[route(POST "/v/{slug}/unlock")]
pub async fn unlock(cx: &Cx, Form(f): Form<UnlockForm>) -> Result<Response> {
    let w = load(cx).await?;
    let back = format!("/v/{}", w.video.slug);
    if w.access == Access::Allowed {
        return see_other(back).into_response(cx);
    }
    if w.access == Access::Denied {
        return Err(not_found().into());
    }
    limit(cx, "unlock", 10, Duration::from_secs(600))?;
    let st = state(cx);
    if !service::verify_video_password(&w.video, f.password)
        .await
        .web()?
    {
        let slug = w.video.slug.clone();
        let html = view! {
            cx =>
            shell(
                meta: Meta { noindex: true, ..Meta::titled("Password required") },
                signed_in: w.member.is_some(),
                password_gate(
                    slug: slug,
                    error: Some("That password is not right.".into())
                )
            )
        }
        .single()
        .await?
        .render(cx);
        let mut res = Response::new(Body::from(html));
        *res.status_mut() = StatusCode::UNPROCESSABLE_ENTITY;
        res.headers_mut().insert(
            header::CONTENT_TYPE,
            HeaderValue::from_static("text/html; charset=utf-8"),
        );
        return Ok(res);
    }
    let name = service::unlock_cookie_name(&w.video);
    let token = service::unlock_token(st, &w.video);
    unlock_jar(cx).add(cookie! {
        name = token;
        HttpOnly;
        SameSite = SameSite::Lax;
        MaxAge = time::Duration::days(7)
    });
    see_other(back).into_response(cx)
}

// ---------- media ----------

fn found(url: &str, cache: &'static str) -> Result<Response> {
    let mut res = Response::new(Body::empty());
    *res.status_mut() = StatusCode::FOUND;
    let h = res.headers_mut();
    h.insert(
        header::LOCATION,
        HeaderValue::from_str(url).map_err(|_| not_found())?,
    );
    h.insert(header::CACHE_CONTROL, HeaderValue::from_static(cache));
    Ok(res)
}

#[route(GET "/v/{slug}/media")]
pub async fn media(cx: &Cx) -> Result<Response> {
    let w = load_allowed(cx).await?;
    if w.video.status != "ready" {
        return Err(not_found().into());
    }
    let url = state(cx)
        .store
        .presign_get(&w.video.object_key, MEDIA_URL_TTL, &w.video.content_type)
        .await
        .map_err(|e| crate::error::AppError::Storage(e.0))
        .web()?;
    found(&url, "private, no-store")
}

#[route(GET "/v/{slug}/download")]
pub async fn download(cx: &Cx) -> Result<Response> {
    let w = load_allowed(cx).await?;
    let v = &w.video;
    if v.status != "ready" {
        return Err(not_found().into());
    }
    let ext = service::video_ext(&v.content_type).unwrap_or("mp4");
    let name: String = v
        .title
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '-' || c == '_' {
                c
            } else {
                '-'
            }
        })
        .collect::<String>()
        .trim_matches('-')
        .chars()
        .take(80)
        .collect();
    let name = if name.is_empty() {
        "recording".into()
    } else {
        name
    };
    let url = state(cx)
        .store
        .presign_get_with(
            &v.object_key,
            SHORT_URL_TTL,
            &v.content_type,
            &format!("attachment; filename=\"{name}.{ext}\""),
        )
        .await
        .map_err(|e| crate::error::AppError::Storage(e.0))
        .web()?;
    found(&url, "no-store")
}

#[route(GET "/v/{slug}/thumbnail.jpg")]
pub async fn thumbnail(cx: &Cx) -> Result<Response> {
    let w = load_allowed(cx).await?;
    let key = w.video.thumbnail_key.as_deref().ok_or_else(not_found)?;
    let url = state(cx)
        .store
        .presign_get(key, SHORT_URL_TTL, "image/jpeg")
        .await
        .map_err(|e| crate::error::AppError::Storage(e.0))
        .web()?;
    found(&url, "private, max-age=300")
}

#[route(GET "/v/{slug}/transcript.vtt")]
pub async fn transcript(cx: &Cx) -> Result<Response> {
    let w = load_allowed(cx).await?;
    let text = service::transcript(state(cx), &w.video)
        .await
        .web()?
        .ok_or_else(not_found)?;
    let mut res = Response::new(Body::from(text));
    let h = res.headers_mut();
    h.insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static("text/vtt; charset=utf-8"),
    );
    h.insert(
        header::CACHE_CONTROL,
        HeaderValue::from_static("private, max-age=300"),
    );
    Ok(res)
}

// ---------- conversation writes ----------

#[derive(Deserialize)]
pub struct CommentForm {
    body: String,
    name: Option<String>,
    at_time: Option<String>,
    timestamp_ms: Option<String>,
}

fn parse_ts(at: bool, raw: Option<&str>) -> Option<i64> {
    if !at {
        return None;
    }
    raw.and_then(|s| s.trim().parse::<f64>().ok())
        .filter(|t| t.is_finite() && *t >= 0.0)
        .map(|t| t as i64)
}

/// Render components to an SSE stream of element patches (a Datastar response).
async fn patches(cx: &Cx, parts: Vec<PatchElements>) -> Result<Response> {
    let events: Vec<Result<Event>> = parts.into_iter().map(|p| Ok(p.into())).collect();
    Sse::new(stream::iter(events)).into_response(cx)
}

/// Morph by id (keeps focus and scroll); `fresh` replaces outright, which also resets
/// typed values, for a form that was just submitted successfully.
fn patch(html: String) -> PatchElements {
    PatchElements::new(html)
}

fn fresh(html: String) -> PatchElements {
    PatchElements::new(html).mode(ElementPatchMode::Replace)
}

#[route(POST "/v/{slug}/comments")]
pub async fn post_comment(cx: &Cx, Form(f): Form<CommentForm>) -> Result<Response> {
    let w = load_allowed(cx).await?;
    let st = state(cx);
    let v = &w.video;
    let enhanced = datastar_request(cx);
    let member_name = w.member.as_ref().map(|m| m.name().to_string());
    let window = Duration::from_secs(60);
    let allowed = match &w.member {
        Some(m) => st
            .limiter
            .allow(&format!("comment:{}", m.user_id), 30, window),
        None => {
            let (ip, _) = fingerprint(cx);
            st.limiter.allow(&format!("comment:{ip}"), 10, window)
        }
    };
    let ts = parse_ts(f.at_time.is_some(), f.timestamp_ms.as_deref());
    let author = match &w.member {
        Some(m) => Author::Member {
            email: m.email.clone(),
        },
        None => Author::Guest {
            name: f.name.clone().unwrap_or_default(),
        },
    };
    let result = if allowed {
        service::add_comment(st, &w.scope, v, author, &f.body, ts).await
    } else {
        Err(crate::error::AppError::RateLimited)
    };
    let error = match result {
        Ok(_) => None,
        Err(crate::error::AppError::Invalid(m)) => Some(m),
        Err(crate::error::AppError::RateLimited) => {
            Some("You're commenting quickly. Wait a minute and try again.".into())
        }
        Err(e) => return Err(e).web(),
    };
    if !enhanced {
        return see_other(format!("/v/{}#comments-card", v.slug)).into_response(cx);
    }
    let slug = v.slug.clone();
    let failed = error.is_some();
    let form = view! {
        cx =>
        comment_form(slug: slug, member_name: member_name, error: error)
    }
    .single()
    .await?
    .render(cx);
    if failed {
        return patches(cx, vec![patch(form)]).await;
    }
    let (comments, markers) = tokio::try_join!(
        service::comments(st, &w.scope, v),
        service::reaction_markers(st, &w.scope, v)
    )
    .web()?;
    let listed = comments.clone();
    let duration = v.duration_ms;
    let list = view! { cx => comments_region(comments: listed, now: now_ms()) }
        .single()
        .await?
        .render(cx);
    let marks = view! {
        cx =>
        markers_region(duration_ms: duration, comments: comments, reactions: markers)
    }
    .single()
    .await?
    .render(cx);
    patches(cx, vec![fresh(form), patch(list), patch(marks)]).await
}

#[derive(Deserialize)]
pub struct ReactionForm {
    emoji: String,
    timestamp_ms: Option<String>,
}

#[route(POST "/v/{slug}/reactions")]
pub async fn post_reaction(cx: &Cx, Form(f): Form<ReactionForm>) -> Result<Response> {
    let w = load_allowed(cx).await?;
    let st = state(cx);
    let v = &w.video;
    let who = match &w.member {
        Some(m) => m.user_id.to_string(),
        None => fingerprint(cx).0,
    };
    if !st
        .limiter
        .allow(&format!("react:{who}"), 30, Duration::from_secs(60))
    {
        return Err(topcoat::router::error::too_many_requests(60).into());
    }
    let ts = parse_ts(true, f.timestamp_ms.as_deref());
    service::add_reaction(st, &w.scope, v, &f.emoji, ts)
        .await
        .web()?;
    if !datastar_request(cx) {
        return see_other(format!("/v/{}", v.slug)).into_response(cx);
    }
    let ((totals, markers), comments) = tokio::try_join!(
        service::reactions(st, &w.scope, v),
        service::comments(st, &w.scope, v)
    )
    .web()?;
    let slug = v.slug.clone();
    let duration = v.duration_ms;
    let bar = view! { cx => reactions_region(slug: slug, totals: totals) }
        .single()
        .await?
        .render(cx);
    let marks = view! {
        cx =>
        markers_region(duration_ms: duration, comments: comments, reactions: markers)
    }
    .single()
    .await?
    .render(cx);
    patches(cx, vec![patch(bar), patch(marks)]).await
}

// ---------- live updates ----------

#[topcoat::router::query_params]
pub struct LiveQuery {
    since: Option<i64>,
}

/// Snapshots older than this on (re)connect are refreshed immediately.
const STALE_AFTER_MS: i64 = 5_000;

struct Live {
    cx: Cx,
    st: AppState,
    scope: Scope,
    /// The session the stream was opened with; when it ends, the page signs out.
    session_id: Option<uuid::Uuid>,
    video: Video,
    sub: Subscription,
    session: Option<Subscription>,
    _slot: StreamSlot,
    queue: std::collections::VecDeque<Event>,
    gone: bool,
    opened: Instant,
}

/// What to re-render. `video` only asks to re-read the row: the regions that depend on
/// what changed in it are decided by comparing it with the last render.
#[derive(Default, Clone, Copy)]
struct Dirty {
    video: bool,
    head: bool,
    player: bool,
    transcript: bool,
    comments: bool,
    reactions: bool,
}

impl Dirty {
    fn all() -> Dirty {
        Dirty {
            video: true,
            head: true,
            player: true,
            transcript: true,
            comments: true,
            reactions: true,
        }
    }
    fn any(&self) -> bool {
        self.video || self.head || self.player || self.transcript || self.comments || self.reactions
    }
}

impl Live {
    /// Re-authorize, then re-render the dirty regions from the database.
    async fn render(&mut self, mut d: Dirty) -> Result<()> {
        // The viewer is re-read on every render: a revoked session or a password change
        // applies on the next patch, not on the next page load.
        let m = member(&self.cx).await?;
        if self.session_id.is_some() && m.as_ref().map(|m| m.session_id) != self.session_id {
            let next = format!("/v/{}", self.video.slug);
            return self.end_with(super::signed_out_patch(&next));
        }
        self.scope = scope_of(&m);
        let st = &self.st;
        let Some(fresh) = service::resolve_share_link(st, &self.scope, &self.video.slug)
            .await
            .web()?
            .filter(|v| v.id == self.video.id)
        else {
            return self.unavailable().await;
        };
        let cookie = unlock_jar(&self.cx).get(&service::unlock_cookie_name(&fresh));
        let unlocked = service::check_unlock(st, &fresh, cookie.as_ref().map(|c| c.value()));
        match self.scope.access(&fresh, unlocked) {
            Access::Allowed => {}
            Access::Denied => return self.unavailable().await,
            Access::NeedsPassword => {
                let cx = &self.cx;
                let slug = fresh.slug.clone();
                let html = view! {
                    cx =>
                    <div id="watch" class="watch-locked">
                        password_gate(slug: slug, error: None)
                    </div>
                }
                .single()
                .await?
                .render(cx);
                return self.end_with(PatchElements::new(html));
            }
        }
        let old = &self.video;
        if fresh.title != old.title
            || fresh.status != old.status
            || fresh.duration_ms != old.duration_ms
        {
            d.head = true;
        }
        if fresh.status != old.status
            || fresh.transcript_key != old.transcript_key
            || fresh.thumbnail_key != old.thumbnail_key
            || (fresh.status != "ready"
                && (fresh.uploaded_bytes != old.uploaded_bytes
                    || fresh.recording_ended_at != old.recording_ended_at))
        {
            d.player = true;
        }
        if fresh.transcript_key.is_some() != old.transcript_key.is_some() {
            d.transcript = true;
        }
        self.video = fresh;
        let v = self.video.clone();
        // Load only what the dirty regions show: a progress tick re-reads the row and
        // nothing else; markers need comments and reactions, the head owner and views.
        let scope = &self.scope;
        let conversation = d.comments || d.reactions || (d.player && v.status == "ready");
        let (head, comments, markers, totals) = tokio::try_join!(
            async {
                if !d.head {
                    return Ok(None);
                }
                tokio::try_join!(owner_name(st, &v), view_count(st, scope, &v)).map(Some)
            },
            async {
                if !conversation {
                    return Ok(Vec::new());
                }
                service::comments(st, scope, &v).await
            },
            async {
                if !conversation {
                    return Ok(Vec::new());
                }
                service::reaction_markers(st, scope, &v).await
            },
            async {
                if !d.reactions {
                    return Ok(Vec::new());
                }
                service::reaction_totals(st, scope, &v).await
            },
        )
        .web()?;
        let cx = &self.cx;
        let url = service::share_url(st, &v.slug);
        let mut out = Vec::new();
        if let Some((owner, views)) = head {
            let video = v.clone();
            out.push(
                view! {
                    cx =>
                    head_region(
                        video: video,
                        owner: owner,
                        views: views,
                        now: now_ms(),
                        url: url
                    )
                }
                .single()
                .await?
                .render(cx),
            );
        }
        if d.player {
            let (video, c, m) = (v.clone(), comments.clone(), markers.clone());
            out.push(
                view! { cx => player_region(video: video, comments: c, reactions: m) }
                    .single()
                    .await?
                    .render(cx),
            );
        } else if d.comments || d.reactions {
            let (duration, c, m) = (v.duration_ms, comments.clone(), markers.clone());
            out.push(
                view! {
                    cx =>
                    markers_region(duration_ms: duration, comments: c, reactions: m)
                }
                .single()
                .await?
                .render(cx),
            );
        }
        if d.transcript {
            let available = v.transcript_key.is_some();
            out.push(
                view! { cx => transcript_region(available: available) }
                    .single()
                    .await?
                    .render(cx),
            );
        }
        if d.comments {
            let c = comments.clone();
            out.push(
                view! { cx => comments_region(comments: c, now: now_ms()) }
                    .single()
                    .await?
                    .render(cx),
            );
        }
        if d.reactions {
            let slug = v.slug.clone();
            out.push(
                view! { cx => reactions_region(slug: slug, totals: totals) }
                    .single()
                    .await?
                    .render(cx),
            );
        }
        self.queue
            .extend(out.into_iter().map(|html| PatchElements::new(html).into()));
        Ok(())
    }

    /// Queue a final patch and end the stream.
    fn end_with(&mut self, patch: PatchElements) -> Result<()> {
        self.gone = true;
        self.queue.push_back(patch.into());
        Ok(())
    }

    /// Deleted, made private or expired: replace the page with a notice.
    async fn unavailable(&mut self) -> Result<()> {
        let cx = &self.cx;
        let html = view! {
            cx =>
            <div id="watch" class="watch-gone">
                <section class="card narrow">
                    <h1>"Recording unavailable"</h1>
                    <p class="muted" role="status">
                        "This recording was deleted, made private, or has expired."
                    </p>
                    <a class="button" href="/">"Easyshot home"</a>
                </section>
            </div>
        }
        .single()
        .await?
        .render(cx);
        self.end_with(PatchElements::new(html))
    }

    async fn next(mut self) -> Option<(Result<Event>, Live)> {
        loop {
            if let Some(e) = self.queue.pop_front() {
                return Some((Ok(e), self));
            }
            if self.gone || self.opened.elapsed() > Duration::from_secs(6 * 3600) {
                return None;
            }
            // Changes arrive through Postgres NOTIFY from every instance; a burst (several
            // views, a comment plus its reaction, progress ticks) coalesces into one render.
            let mut ping = next_ping(&mut self.sub, self.session.as_mut()).await;
            ping.as_ref()?;
            let mut dirty = Dirty::default();
            while let Some(p) = ping {
                match p.change {
                    Change::Comments => dirty.comments = true,
                    Change::Reactions => dirty.reactions = true,
                    Change::Video => dirty.video = true,
                    Change::Views => dirty.head = true,
                    // Gone, a session change or a resync: re-check access and render it all.
                    Change::Gone | Change::Session | Change::Resync => dirty = Dirty::all(),
                    _ => {}
                }
                ping = try_ping(&mut self.sub, self.session.as_mut());
            }
            if !dirty.any() {
                continue;
            }
            if let Err(e) = self.render(dirty).await {
                return Some((Err(e), self));
            }
        }
    }
}

#[route(GET "/v/{slug}/live")]
pub async fn live(cx: &Cx) -> Result<Sse<impl Stream<Item = Result<Event>> + Send + use<>>> {
    let w = load_allowed(cx).await?;
    let st = state(cx).clone();
    let since = query_params::<LiveQuery>(cx)
        .ok()
        .and_then(|q| q.since)
        .unwrap_or(0);
    let slot = super::admit_stream(cx, &w.member)?;
    let sub = st.live.subscribe(&w.video.id);
    let session = w.member.as_ref().map(|m| {
        st.live
            .subscribe(&Hub::session_topic(&m.session_id.to_string()))
    });
    let mut live = Live {
        cx: cx.clone(),
        st,
        scope: w.scope,
        session_id: w.member.as_ref().map(|m| m.session_id),
        video: w.video,
        sub,
        session,
        _slot: slot,
        queue: Default::default(),
        gone: false,
        opened: Instant::now(),
    };
    if now_ms() - since > STALE_AFTER_MS {
        live.render(Dirty::all()).await?;
    }
    let events = stream::unfold(live, |l| l.next());
    Ok(Sse::new(events).keep_alive(KeepAlive::new().interval(Duration::from_secs(15))))
}

// ---------- oEmbed ----------

#[topcoat::router::query_params]
pub struct OembedQuery {
    url: Option<String>,
    maxwidth: Option<i64>,
}

#[route(GET "/oembed")]
pub async fn oembed(cx: &Cx) -> Result<Response> {
    let st = state(cx);
    let q = query_params::<OembedQuery>(cx).map_err(|_| not_found())?;
    let url = q.url.as_deref().ok_or_else(not_found)?;
    let base = &st.config.public_base_url;
    let slug = url
        .strip_prefix(base.as_str())
        .and_then(|p| p.strip_prefix("/v/"))
        .map(|s| s.trim_end_matches('/'))
        .ok_or_else(not_found)?;
    let v = service::resolve_share_link(st, &Scope::anonymous(), slug)
        .await
        .web()?
        .filter(|v| {
            Visibility::parse(&v.visibility) == Some(Visibility::Link) && v.status == "ready"
        })
        .ok_or_else(not_found)?;
    let (w, h) = (v.width.unwrap_or(1280), v.height.unwrap_or(720));
    let width = q
        .maxwidth
        .filter(|m| *m > 0)
        .map_or(w, |m| m.min(w))
        .min(1280);
    let height = width * h / w.max(1);
    let author = owner_name(st, &v).await.web()?;
    let embed_url = format!("{base}/v/{}/embed", v.slug);
    let mut body = serde_json::json!({
        "version": "1.0",
        "type": "video",
        "provider_name": "Easyshot",
        "provider_url": base,
        "title": v.title,
        "author_name": author,
        "width": width,
        "height": height,
        "html": format!(
            "<iframe src=\"{embed_url}\" width=\"{width}\" height=\"{height}\" frameborder=\"0\" allow=\"fullscreen; picture-in-picture\" allowfullscreen></iframe>"
        ),
    });
    if v.thumbnail_key.is_some() {
        body["thumbnail_url"] = format!("{base}{}", thumb_url(&v)).into();
        body["thumbnail_width"] = w.into();
        body["thumbnail_height"] = h.into();
    }
    let mut res = Response::new(Body::from(body.to_string()));
    let hd = res.headers_mut();
    hd.insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static("application/json"),
    );
    hd.insert(
        header::CACHE_CONTROL,
        HeaderValue::from_static("public, max-age=300"),
    );
    Ok(res)
}
