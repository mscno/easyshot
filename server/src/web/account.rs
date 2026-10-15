//! Landing page and the owner's library. The library keeps one live stream: recordings
//! appear the instant the Mac app creates them, show upload progress while it records, and
//! renames, privacy changes, deletes, comments and views from anywhere patch in place.

use std::collections::{HashMap, VecDeque};
use std::future::Future;
use std::time::{Duration, Instant};

use futures_util::{Stream, stream};
use serde::Deserialize;
use topcoat::{
    Result,
    context::Cx,
    datastar::{ElementPatchMode, PatchElements, datastar_request},
    router::{
        content::{
            Form,
            sse::{Event, KeepAlive, Sse},
        },
        error::{redirect, see_other, unauthorized},
        page, path_param, query_params,
        response::{IntoResponse, Response},
        route,
    },
    view::{View, ViewExt, component, view},
};
use uuid::Uuid;

use super::layout::{Meta, ago, clock, plural, shell};
use super::watch::upload_status;
use super::{Member, WebResult, admit_stream, member, signed_out_patch, state};
use crate::db::Context;
use crate::error::AppError;
use crate::mailer::Email;
use crate::repo::{self, Screenshot, now_ms};
use crate::routes::auth::normalize_email;
use crate::state::AppState;
use crate::video::live::{Change, Hub, StreamSlot, Subscription, next_ping, try_ping};
use crate::video::model::Video;
use crate::video::scope::{Scope, Visibility};
use crate::video::service::{self, Edit, share_url};

// ---------- landing ----------

#[page("/")]
pub async fn landing(cx: &Cx) -> Result<impl View> {
    let signed_in = member(cx).await?.is_some();
    let download = state(cx).config.download_url.clone();
    let meta = Meta {
        title: "Easyshot".into(),
        description: Some(
            "Record your screen on the Mac and share a link before you stop talking.".into(),
        ),
        ..Meta::default()
    };
    Ok(view! {
        shell(
            meta: meta,
            signed_in: signed_in,
            <section class="hero">
                <p class="eyebrow">"Screen recording for Mac"</p>
                <h1>"Record it. Share the link. Get answers."</h1>
                <p class="lede">
                    "Easyshot uploads while you record, so the link is on your clipboard the moment you stop. "
                    "Teammates watch in the browser, react, and leave comments pinned to the exact second."
                </p>
                <div class="cta">
                    <a class="button primary" href=(download.as_str())>
                        "Download for Mac"
                    </a>
                    if signed_in {
                        <a class="button" href="/library">"Your library"</a>
                    } else {
                        <a class="button" href="/signup">"Create a free account"</a>
                    }
                </div>
                <p class="fineprint">"Apple Silicon · macOS 26 or later"</p>
            </section>
            <section class="features">
                <article>
                    <h2>"Instant links"</h2>
                    <p>
                        "Parts stream to storage during the recording. Stop, and the link already works."
                    </p>
                </article>
                <article>
                    <h2>"Comments on the timeline"</h2>
                    <p>
                        "Viewers comment and react at a moment in the video. Everyone watching sees it live."
                    </p>
                </article>
                <article>
                    <h2>"Transcripts from your Mac"</h2>
                    <p>
                        "Speech is transcribed on-device and shown next to the video. Click a line to jump there."
                    </p>
                </article>
                <article>
                    <h2>"You choose who watches"</h2>
                    <p>
                        "Anyone with the link, a password, or only you. Links expire automatically."
                    </p>
                </article>
            </section>
            <section class="privacy">
                <h2>"Private by default"</h2>
                <p>
                    "Recording and encoding happen on your Mac. Easyshot has no tracking, no analytics and no ads. "
                    "Views are counted with a daily keyed hash, never your IP address."
                </p>
            </section>
        )
    })
}

// ---------- library ----------

async fn require_member(cx: &Cx, next: &str) -> Result<Member> {
    match member(cx).await? {
        Some(m) => Ok(m),
        None => Err(redirect(format!("/login?next={next}")).into()),
    }
}

/// What a card shows besides the video row itself.
#[derive(Clone, Copy, Default)]
struct Counts {
    views: i64,
    comments: i64,
}

async fn counts(st: &AppState, scope: &Scope, ids: &[&str]) -> Result<HashMap<String, Counts>> {
    let views = service::view_counts(st, scope.context(), ids).await.web()?;
    let comments = service::comment_counts(st, scope.context(), ids)
        .await
        .web()?;
    Ok(ids
        .iter()
        .map(|id| {
            let c = Counts {
                views: views.get(*id).copied().unwrap_or(0),
                comments: comments.get(*id).copied().unwrap_or(0),
            };
            (id.to_string(), c)
        })
        .collect())
}

/// Everything the library shows; rendered on the page and re-rendered by the stream.
struct Library {
    videos: Vec<Video>,
    counts: HashMap<String, Counts>,
    shots: Vec<Screenshot>,
}

const LIBRARY_LIMIT: usize = 200;
const SHOT_LIMIT: i64 = 50;

async fn load_library(st: &AppState, user_id: Uuid) -> Result<Library> {
    let scope = Scope::user(user_id);
    let videos = scope.items(st, LIBRARY_LIMIT).await.web()?;
    let ids: Vec<&str> = videos.iter().map(|v| v.id.as_str()).collect();
    let counts = counts(st, &scope, &ids).await?;
    let shots = repo::list_ready(
        &st.db.scoped(Context::user(user_id)),
        user_id,
        now_ms(),
        None,
        SHOT_LIMIT,
    )
    .await
    .map_err(AppError::from)
    .web()?;
    Ok(Library {
        videos,
        counts,
        shots,
    })
}

#[page("/library")]
pub async fn library(cx: &Cx) -> Result<impl View> {
    let m = require_member(cx, "/library").await?;
    let st = state(cx);
    let lib = load_library(st, m.user_id).await?;
    let mail = st.mailer.enabled();
    let base = st.config.public_base_url.clone();
    let now = now_ms();
    let live = format!(
        "@get('/library/live?since={now}', {{retry: 'always', retryMaxCount: 1000}})"
    );
    Ok(view! {
        shell(
            meta: Meta { noindex: true, ..Meta::titled("Library") },
            signed_in: true,
            <section class="library" data-init=(live.as_str())>
                <div class="library-head">
                    <h1>"Library"</h1>
                    <p class="muted">
                        "Signed in as "
                        (m.email.as_str())
                    </p>
                </div>
                items_region(videos: lib.videos, counts: lib.counts, base: base.clone(), mail: mail, now: now)
                shots_region(shots: lib.shots, base: base, now: now)
            </section>
        )
    })
}

#[component]
async fn items_region(
    videos: Vec<Video>,
    counts: HashMap<String, Counts>,
    base: String,
    mail: bool,
    now: i64,
) -> Result<impl View> {
    Ok(view! {
        <div id="library-items">
            if videos.is_empty() {
                <div id="library-empty" class="empty card">
                    <h2>"No recordings yet"</h2>
                    <p>
                        "Record in the Easyshot app with Easyshot Cloud enabled. The link appears here and on your clipboard."
                    </p>
                </div>
            }
            <div id="items" class="items">
                #[key(v.id.clone())]
                for v in videos {
                    let c = counts.get(&v.id).copied().unwrap_or_default();
                    item_card(
                        video: v,
                        views: c.views,
                        comments: c.comments,
                        base: base.clone(),
                        mail: mail,
                        now: now,
                        notice: None
                    )
                }
            </div>
        </div>
    })
}

#[component]
async fn shots_region(shots: Vec<Screenshot>, base: String, now: i64) -> Result<impl View> {
    Ok(view! {
        <section id="shots" class="shots">
            if !shots.is_empty() {
                <h2>"Screenshot links"</h2>
                <ul class="list">
                    #[key(s.id.to_string())]
                    for s in shots {
                        let link = format!("{base}/s/{}", s.slug);
                        let li = format!("shot-{}", s.id);
                        <li id=(li.as_str()) class="list-row">
                            <div>
                                <a href=(link.as_str())>
                                    (s.filename.clone().unwrap_or_else(|| "Screenshot".into()))
                                </a>
                                <p class="muted small">
                                    (ago(s.created_at, now))
                                    if let (Some(w), Some(h)) = (s.width, s.height) {
                                        " · "
                                        (format!("{w}×{h}"))
                                    }
                                </p>
                            </div>
                            <button type="button" class="button small" data-copy=(link.as_str())>
                                "Copy link"
                            </button>
                        </li>
                    }
                </ul>
            }
        </section>
    })
}

/// The parts of a card that change while a recording uploads or gets watched; patched on
/// their own so an open "Manage" panel and half-typed input survive.
#[component]
async fn card_meta(video: Video, views: i64, comments: i64, now: i64) -> Result<impl View> {
    let v = video;
    let id = v.id.clone();
    let meta_id = format!("meta-{id}");
    let visibility = Visibility::parse(&v.visibility).unwrap_or(Visibility::Private);
    let pending = v.status != "ready";
    Ok(view! {
        <p id=(meta_id.as_str()) class="muted small">
            (ago(v.created_at, now))
            " · "
            (plural(views, "view", "views"))
            " · "
            (plural(comments, "comment", "comments"))
            " · "
            (visibility.label())
            if pending {
                " · "
                <span class="pill live">(upload_status(&v))</span>
            }
        </p>
    })
}

#[component]
async fn card_thumb(video: Video, link: String) -> Result<impl View> {
    let v = video;
    let thumb_id = format!("thumb-{}", v.id);
    let thumb = format!("/v/{}/thumbnail.jpg", v.slug);
    Ok(view! {
        <a id=(thumb_id.as_str()) class="thumb" href=(link.as_str())>
            if v.thumbnail_key.is_some() {
                <img src=(thumb.as_str()) alt="" loading="lazy">
            } else {
                <span class="thumb-empty">"▶"</span>
            }
            if v.duration_ms > 0 {
                <span class="badge">(clock(v.duration_ms))</span>
            }
        </a>
    })
}

#[allow(clippy::too_many_arguments)]
#[component]
pub async fn item_card(
    video: Video,
    views: i64,
    comments: i64,
    base: String,
    mail: bool,
    now: i64,
    notice: Option<String>,
) -> Result<impl View> {
    let v = video;
    let id = v.id.clone();
    let link = format!("{base}/v/{}", v.slug);
    let card_id = format!("item-{id}");
    let action = |what: &str| format!("/library/{id}/{what}");
    let enhance = |what: &str| {
        format!(
            "@post('/library/{id}/{what}', {{contentType: 'form', retry: 'never', retryMaxCount: 0}})"
        )
    };
    let (rename_url, rename_js) = (action("rename"), enhance("rename"));
    let (vis_url, vis_js) = (action("visibility"), enhance("visibility"));
    let (send_url, send_js) = (action("send"), enhance("send"));
    let delete_url = action("delete");
    let delete_js = format!(
        "if (confirm('Delete this recording for everyone?')) {{ {} }}",
        enhance("delete")
    );
    let (title_id, vis_id, to_id) = (
        format!("title-{id}"),
        format!("vis-{id}"),
        format!("to-{id}"),
    );
    let visibility = Visibility::parse(&v.visibility).unwrap_or(Visibility::Private);
    Ok(view! {
        <article id=(card_id.as_str()) class="item card">
            card_thumb(video: v.clone(), link: link.clone())
            <div class="item-body">
                <a class="item-title" href=(link.as_str())>(v.title.as_str())</a>
                card_meta(video: v.clone(), views: views, comments: comments, now: now)
                match notice {
                    Some(n) => <p class="notice" role="status">(n)</p>,
                    None => "",
                }
                <div class="row">
                    <button
                        type="button"
                        class="button small"
                        data-copy=(link.as_str())
                    >
                        "Copy link"
                    </button>
                    <a class="button small" href=(link.as_str())>"Open"</a>
                </div>
                <details class="manage">
                    <summary>"Manage"</summary>
                    <form
                        method="post"
                        action=(rename_url.as_str())
                        class="row"
                        data-on:submit=(rename_js.as_str())
                    >
                        <label class="sr-only" for=(title_id.as_str())>"Title"</label>
                        <input
                            id=(title_id.as_str())
                            name="title"
                            value=(v.title.as_str())
                            maxlength="200"
                            required=""
                        >
                        <button type="submit" class="button small">"Rename"</button>
                    </form>
                    <form
                        method="post"
                        action=(vis_url.as_str())
                        class="row"
                        data-on:submit=(vis_js.as_str())
                    >
                        <label class="sr-only" for=(vis_id.as_str())>
                            "Who can watch"
                        </label>
                        <select id=(vis_id.as_str()) name="visibility">
                            for opt in Visibility::ALL {
                                <option value=(opt.as_str()) selected=(opt == visibility)>
                                    (opt.label())
                                </option>
                            }
                        </select>
                        <input
                            name="password"
                            type="password"
                            placeholder="Password"
                            maxlength="128"
                            autocomplete="new-password"
                        >
                        <button type="submit" class="button small">"Save"</button>
                    </form>
                    if mail {
                        <form
                            method="post"
                            action=(send_url.as_str())
                            class="row"
                            data-on:submit=(send_js.as_str())
                        >
                            <label class="sr-only" for=(to_id.as_str())>
                                "Send to"
                            </label>
                            <input
                                id=(to_id.as_str())
                                name="to"
                                type="email"
                                placeholder="teammate@company.com"
                                required=""
                            >
                            <button type="submit" class="button small">"Send"</button>
                        </form>
                    }
                    <form
                        method="post"
                        action=(delete_url.as_str())
                        class="row"
                        data-on:submit=(delete_js.as_str())
                    >
                        <button type="submit" class="button small danger">
                            "Delete"
                        </button>
                    </form>
                </details>
            </div>
        </article>
    })
}

path_param!(pub id);

#[derive(Deserialize)]
pub struct RenameForm {
    title: String,
}

#[derive(Deserialize)]
pub struct VisibilityForm {
    visibility: String,
    password: Option<String>,
}

#[derive(Deserialize)]
pub struct SendForm {
    to: String,
}

async fn managed(cx: &Cx) -> Result<(Member, Scope, Video)> {
    let m = require_member(cx, "/library").await?;
    let id = path_param::<Id>(cx);
    let scope = Scope::user(m.user_id);
    let v = scope.managed(state(cx), id).await.web()?;
    Ok((m, scope, v))
}

async fn render_card(
    cx: &Cx,
    st: &AppState,
    scope: &Scope,
    v: Video,
    notice: Option<String>,
) -> Result<String> {
    let c = counts(st, scope, &[v.id.as_str()])
        .await?
        .remove(&v.id)
        .unwrap_or_default();
    let base = st.config.public_base_url.clone();
    let mail = st.mailer.enabled();
    Ok(view! {
        cx =>
        item_card(
            video: v,
            views: c.views,
            comments: c.comments,
            base: base,
            mail: mail,
            now: now_ms(),
            notice: notice
        )
    }
    .single()
    .await?
    .render(cx))
}

/// Datastar gets the refreshed card; a plain form post returns to the library.
async fn card_response(
    cx: &Cx,
    scope: &Scope,
    v: Video,
    notice: Option<String>,
) -> Result<Response> {
    if !datastar_request(cx) {
        return see_other("/library").into_response(cx);
    }
    let html = render_card(cx, state(cx), scope, v, notice).await?;
    PatchElements::new(html).into_response(cx)
}

#[route(POST "/library/{id}/rename")]
pub async fn item_rename(cx: &Cx, Form(f): Form<RenameForm>) -> Result<Response> {
    let (_, scope, v) = managed(cx).await?;
    let v = service::edit(
        state(cx),
        &scope,
        &v,
        Edit {
            title: Some(f.title),
            ..Edit::default()
        },
    )
    .await
    .web()?;
    card_response(cx, &scope, v, Some("Renamed.".into())).await
}

#[route(POST "/library/{id}/visibility")]
pub async fn item_visibility(cx: &Cx, Form(f): Form<VisibilityForm>) -> Result<Response> {
    let (_, scope, v) = managed(cx).await?;
    let Some(vis) = Visibility::parse(&f.visibility) else {
        return card_response(cx, &scope, v, Some("Choose who can watch.".into())).await;
    };
    let password = f.password.filter(|p| !p.is_empty());
    match service::edit(
        state(cx),
        &scope,
        &v,
        Edit {
            visibility: Some(vis),
            password,
            ..Edit::default()
        },
    )
    .await
    {
        Ok(v) => card_response(cx, &scope, v, Some(format!("Now: {}.", vis.label()))).await,
        Err(AppError::Invalid(msg)) => card_response(cx, &scope, v, Some(msg)).await,
        Err(e) => Err(e).web(),
    }
}

#[route(POST "/library/{id}/delete")]
pub async fn item_delete(cx: &Cx) -> Result<Response> {
    let (_, scope, v) = managed(cx).await?;
    service::purge(state(cx), &scope.context(), &v)
        .await
        .web()?;
    if datastar_request(cx) {
        let events = vec![Ok::<Event, topcoat::Error>(
            PatchElements::remove(format!("#item-{}", v.id)).into(),
        )];
        return Sse::new(stream::iter(events)).into_response(cx);
    }
    see_other("/library").into_response(cx)
}

#[route(POST "/library/{id}/send")]
pub async fn item_send(cx: &Cx, Form(f): Form<SendForm>) -> Result<Response> {
    let (m, scope, v) = managed(cx).await?;
    let st = state(cx);
    if !st.mailer.enabled() {
        return card_response(
            cx,
            &scope,
            v,
            Some("Email is not configured on this server.".into()),
        )
        .await;
    }
    let Ok(to) = normalize_email(&f.to) else {
        return card_response(cx, &scope, v, Some("Enter a valid email address.".into())).await;
    };
    if !st.limiter.allow(
        &format!("send:{}", m.user_id),
        20,
        Duration::from_secs(3600),
    ) {
        return card_response(
            cx,
            &scope,
            v,
            Some("Too many emails sent. Try again later.".into()),
        )
        .await;
    }
    let link = share_url(st, &v.slug);
    let email = share_email(&to, m.name(), &v.title, &link);
    if let Err(e) = st.mailer.send(email).await {
        tracing::error!(error = %e, "share email failed");
        return card_response(cx, &scope, v, Some("The email could not be sent.".into())).await;
    }
    card_response(cx, &scope, v, Some(format!("Sent to {to}."))).await
}

fn esc(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}

pub fn share_email(to: &str, from_name: &str, title: &str, link: &str) -> Email {
    let subject = format!("{from_name} shared a recording: {title}");
    let text = format!("{from_name} shared \"{title}\" with you.\n\nWatch: {link}\n");
    let html = format!(
        "<div style=\"font-family:-apple-system,Helvetica,Arial,sans-serif;max-width:480px;margin:0 auto;padding:24px;color:#1d1d1f\">\
         <p><strong>{}</strong> shared a recording with you.</p>\
         <p style=\"font-size:18px;font-weight:600\">{}</p>\
         <p><a href=\"{}\" style=\"display:inline-block;background:#ff6a3d;color:#fff;padding:10px 18px;border-radius:8px;text-decoration:none\">Watch</a></p></div>",
        esc(from_name),
        esc(title),
        esc(link)
    );
    Email {
        to: to.to_string(),
        subject,
        text,
        html,
        idempotency_key: format!("share-{}", Uuid::new_v4()),
    }
}

// ---------- live library ----------

/// What a card was last rendered with, to choose between a meta patch and a full card.
#[derive(PartialEq)]
struct Shown {
    title: String,
    visibility: String,
    ready: bool,
    thumb: bool,
    duration: i64,
}

impl Shown {
    fn of(v: &Video) -> Shown {
        Shown {
            title: v.title.clone(),
            visibility: v.visibility.clone(),
            ready: v.status == "ready",
            thumb: v.thumbnail_key.is_some(),
            duration: v.duration_ms,
        }
    }
}

struct Live {
    cx: Cx,
    st: AppState,
    user_id: Uuid,
    session_id: Uuid,
    shown: HashMap<String, Shown>,
    user: Subscription,
    session: Subscription,
    _slot: StreamSlot,
    queue: VecDeque<Event>,
    done: bool,
    opened: Instant,
}

/// Rows to refresh after a burst of pings.
#[derive(Default)]
struct Dirty {
    all: bool,
    shots: bool,
    items: Vec<String>,
}

impl Live {
    fn push(&mut self, p: PatchElements) {
        self.queue.push_back(p.into());
    }

    /// Re-check the session; `false` (with a sign-out patch queued) when it ended.
    async fn authorized(&mut self) -> Result<bool> {
        let ok = member(&self.cx)
            .await?
            .is_some_and(|m| m.session_id == self.session_id && m.user_id == self.user_id);
        if !ok {
            self.done = true;
            self.push(signed_out_patch("/library"));
        }
        Ok(ok)
    }

    async fn render_all(&mut self) -> Result<()> {
        let lib = load_library(&self.st, self.user_id).await?;
        self.shown = lib
            .videos
            .iter()
            .map(|v| (v.id.clone(), Shown::of(v)))
            .collect();
        let base = self.st.config.public_base_url.clone();
        let items_base = base.clone();
        let mail = self.st.mailer.enabled();
        let now = now_ms();
        let cx = &self.cx;
        let Library {
            videos,
            counts,
            shots,
        } = lib;
        let items = view! {
            cx =>
            items_region(videos: videos, counts: counts, base: items_base, mail: mail, now: now)
        }
        .single()
        .await?
        .render(cx);
        let shots = view! { cx => shots_region(shots: shots, base: base, now: now) }
            .single()
            .await?
            .render(cx);
        self.push(PatchElements::new(items));
        self.push(PatchElements::new(shots));
        Ok(())
    }

    async fn render_shots(&mut self) -> Result<()> {
        let shots = load_library(&self.st, self.user_id).await?.shots;
        let base = self.st.config.public_base_url.clone();
        let cx = &self.cx;
        let html = view! { cx => shots_region(shots: shots, base: base, now: now_ms()) }
            .single()
            .await?
            .render(cx);
        self.push(PatchElements::new(html));
        Ok(())
    }

    /// One recording changed (or appeared, or went away).
    async fn render_item(&mut self, id: &str) -> Result<()> {
        let scope = Scope::user(self.user_id);
        let v = match scope.managed(&self.st, id).await {
            Ok(v) => v,
            Err(AppError::NotFound) => {
                if self.shown.remove(id).is_some() {
                    self.push(PatchElements::remove(format!("#item-{id}")));
                    if self.shown.is_empty() {
                        return self.render_all().await;
                    }
                }
                return Ok(());
            }
            Err(e) => return Err(e).web(),
        };
        let shown = Shown::of(&v);
        let cx = &self.cx;
        match self.shown.get(id) {
            None => {
                // New recording: put it first, drop the empty-state card.
                let card = render_card(cx, &self.st, &scope, v, None).await?;
                if self.shown.is_empty() {
                    self.push(PatchElements::remove("#library-empty"));
                }
                self.push(
                    PatchElements::new(card)
                        .selector("#items")
                        .mode(ElementPatchMode::Prepend),
                );
            }
            Some(old) if *old == shown => {
                // Progress, counts: only the line that changes.
                let c = counts(&self.st, &scope, &[id])
                    .await?
                    .remove(id)
                    .unwrap_or_default();
                let html = view! {
                    cx => card_meta(video: v, views: c.views, comments: c.comments, now: now_ms())
                }
                .single()
                .await?
                .render(cx);
                self.push(PatchElements::new(html));
            }
            Some(_) => {
                let card = render_card(cx, &self.st, &scope, v, None).await?;
                self.push(PatchElements::new(card));
            }
        }
        self.shown.insert(id.to_string(), shown);
        Ok(())
    }

    async fn render(&mut self, d: Dirty) -> Result<()> {
        if !self.authorized().await? {
            return Ok(());
        }
        if d.all {
            return self.render_all().await;
        }
        for id in d.items {
            self.render_item(&id).await?;
        }
        if d.shots {
            self.render_shots().await?;
        }
        Ok(())
    }

    async fn next(mut self) -> Option<(Result<Event>, Live)> {
        loop {
            if let Some(e) = self.queue.pop_front() {
                return Some((Ok(e), self));
            }
            if self.done || self.opened.elapsed() > Duration::from_secs(6 * 3600) {
                return None;
            }
            let mut ping = next_ping(&mut self.user, Some(&mut self.session)).await;
            ping.as_ref()?;
            let mut d = Dirty::default();
            while let Some(p) = ping {
                match p.change {
                    Change::Video
                    | Change::Gone
                    | Change::Comments
                    | Change::Views
                    | Change::Reactions => {
                        if !d.items.iter().any(|i| **i == *p.item) {
                            d.items.push(p.item.to_string());
                        }
                    }
                    Change::Screenshots => d.shots = true,
                    Change::Session | Change::Resync => d.all = true,
                    _ => {}
                }
                ping = try_ping(&mut self.user, Some(&mut self.session));
            }
            if !d.all && !d.shots && d.items.is_empty() {
                continue;
            }
            if let Err(e) = self.render(d).await {
                return Some((Err(e), self));
            }
        }
    }
}

#[query_params]
pub struct LiveQuery {
    since: Option<i64>,
}

#[route(GET "/library/live")]
pub async fn library_live(
    cx: &Cx,
) -> Result<Sse<impl Stream<Item = Result<Event>> + Send + use<>>> {
    let Some(m) = member(cx).await? else {
        return Err(unauthorized().into());
    };
    let st = state(cx).clone();
    let slot = admit_stream(cx, &Some(m.clone()))?;
    let since = query_params::<LiveQuery>(cx)
        .ok()
        .and_then(|q| q.since)
        .unwrap_or(0);
    let mut live = Live {
        cx: cx.clone(),
        user: st.live.subscribe(&Hub::user_topic(&m.user_id.to_string())),
        session: st
            .live
            .subscribe(&Hub::session_topic(&m.session_id.to_string())),
        st,
        user_id: m.user_id,
        session_id: m.session_id,
        shown: HashMap::new(),
        _slot: slot,
        queue: VecDeque::new(),
        done: false,
        opened: Instant::now(),
    };
    // Know what the page shows even when it is fresh, so later pings patch correctly.
    let lib = load_library(&live.st, m.user_id).await?;
    live.shown = lib
        .videos
        .iter()
        .map(|v| (v.id.clone(), Shown::of(v)))
        .collect();
    if now_ms() - since > 5_000 {
        live.render_all().await?;
    }
    let events = stream::unfold(live, |l| l.next());
    Ok(Sse::new(events).keep_alive(KeepAlive::new().interval(Duration::from_secs(15))))
}
