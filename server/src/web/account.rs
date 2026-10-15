//! Landing page, email-code sign-in and the owner's library.

use std::future::Future;
use std::time::Duration;

use futures_util::stream;
use serde::Deserialize;
use topcoat::{
    Result,
    context::Cx,
    datastar::{PatchElements, datastar_request},
    router::{
        StatusCode,
        content::{
            Form,
            sse::{Event, Sse},
        },
        error::{redirect, see_other},
        page, path_param, query_params,
        response::{IntoResponse, Response},
        route,
    },
    session,
    view::{View, ViewExt, component, view},
};
use uuid::Uuid;

use super::layout::{Meta, ago, clock, plural, shell};
use super::{Member, WebResult, hex, member, state};
use crate::mailer::{CodePurpose, Email};
use crate::repo::{self, now_ms};
use crate::routes::auth::normalize_email;
use crate::routes::codes::{check_code, send_code};
use crate::video::model::Video;
use crate::video::scope::{Scope, Visibility};
use crate::video::service::{self, Edit, share_url};

// ---------- landing ----------

#[page("/")]
pub async fn landing(cx: &Cx) -> Result<impl View> {
    let signed_in = member(cx).await?.is_some();
    let download = state(cx).config.download_url.clone();
    let meta = Meta {
        title: "Shotglass".into(),
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
                    "Shotglass uploads while you record, so the link is on your clipboard the moment you stop. "
                    "Teammates watch in the browser, react, and leave comments pinned to the exact second."
                </p>
                <div class="cta">
                    <a class="button primary" href=(download.as_str())>
                        "Download for Mac"
                    </a>
                    <a
                        class="button"
                        href=(if signed_in { "/library" } else { "/login" })
                    >
                        (if signed_in { "Your library" } else { "Sign in" })
                    </a>
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
                    "Recording and encoding happen on your Mac. Shotglass has no tracking, no analytics and no ads. "
                    "Views are counted with a daily keyed hash, never your IP address."
                </p>
            </section>
        )
    })
}

// ---------- sign in ----------

#[query_params]
pub struct LoginQuery {
    next: Option<String>,
}

/// Only local destinations that we serve after sign-in.
fn safe_next(next: Option<&str>) -> String {
    match next {
        Some(n)
            if (n.starts_with("/v/") || n == "/library")
                && n.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'/') =>
        {
            n.to_string()
        }
        _ => "/library".into(),
    }
}

enum LoginStep {
    Email {
        error: Option<String>,
    },
    Code {
        email: String,
        error: Option<String>,
    },
}

#[component]
async fn login_card(next: String, step: LoginStep, mail_ok: bool) -> Result<impl View> {
    Ok(view! {
        shell(
            meta: Meta { noindex: true, ..Meta::titled("Sign in") },
            signed_in: false,
            <section class="card narrow">
                <h1>"Sign in"</h1>
                if !mail_ok {
                    <p class="notice error" role="alert">
                        "Email sign-in is not configured on this server."
                    </p>
                }
                match step {
                    LoginStep::Email { error } => {
                        <p class="muted">
                            "We'll email you a 6-digit code. Accounts are created in the Shotglass app."
                        </p>
                        match error {
                            Some(e) => <p class="notice error" role="alert">(e)</p>,
                            None => "",
                        }
                        <form method="post" action="/login" class="stack">
                            <input type="hidden" name="next" value=(next.as_str())>
                            <label for="email">"Email"</label>
                            <input
                                id="email"
                                name="email"
                                type="email"
                                required=""
                                autocomplete="email"
                                autofocus=""
                            >
                            <button type="submit" class="button primary">
                                "Email me a code"
                            </button>
                        </form>
                    }
                    LoginStep::Code { email, error } => {
                        <p class="muted">
                            "If "
                            <strong>(email.as_str())</strong>
                            " has a Shotglass account, a code is on its way."
                        </p>
                        match error {
                            Some(e) => <p class="notice error" role="alert">(e)</p>,
                            None => "",
                        }
                        <form method="post" action="/login/verify" class="stack">
                            <input type="hidden" name="next" value=(next.as_str())>
                            <input type="hidden" name="email" value=(email.as_str())>
                            <label for="code">"Code"</label>
                            <input
                                id="code"
                                name="code"
                                inputmode="numeric"
                                pattern="[0-9]{6}"
                                maxlength="6"
                                required=""
                                autocomplete="one-time-code"
                                autofocus=""
                            >
                            <button type="submit" class="button primary">
                                "Sign in"
                            </button>
                        </form>
                        <form method="post" action="/login" class="inline">
                            <input type="hidden" name="next" value=(next.as_str())>
                            <input type="hidden" name="email" value=(email.as_str())>
                            <button type="submit" class="link">
                                "Send a new code"
                            </button>
                        </form>
                    }
                }
            </section>
        )
    })
}

#[page("/login")]
pub async fn login_page(cx: &Cx) -> Result<impl View> {
    let next = safe_next(
        query_params::<LoginQuery>(cx)
            .ok()
            .and_then(|q| q.next.as_deref()),
    );
    if member(cx).await?.is_some() {
        return Err(redirect(next).into());
    }
    let mail_ok = state(cx).mailer.enabled();
    Ok(view! {
        login_card(next: next, step: LoginStep::Email { error: None }, mail_ok: mail_ok)
    })
}

/// Render the sign-in card as a full response from a route handler.
async fn login_response(
    cx: &Cx,
    next: String,
    step: LoginStep,
    status: StatusCode,
) -> Result<Response> {
    let mail_ok = state(cx).mailer.enabled();
    let html = view! { cx => login_card(next: next, step: step, mail_ok: mail_ok) }
        .single()
        .await?
        .render(cx);
    let mut res = Response::new(html.into());
    *res.status_mut() = status;
    res.headers_mut().insert(
        topcoat::router::header::CONTENT_TYPE,
        topcoat::router::HeaderValue::from_static("text/html; charset=utf-8"),
    );
    Ok(res)
}

#[derive(Deserialize)]
pub struct LoginForm {
    email: String,
    next: Option<String>,
}

#[route(POST "/login")]
pub async fn login_submit(cx: &Cx, Form(f): Form<LoginForm>) -> Result<Response> {
    let next = safe_next(f.next.as_deref());
    let st = state(cx);
    let Ok(email) = normalize_email(&f.email) else {
        let step = LoginStep::Email {
            error: Some("Enter a valid email address.".into()),
        };
        return login_response(cx, next, step, StatusCode::UNPROCESSABLE_ENTITY).await;
    };
    super::limit(cx, "login", 10, Duration::from_secs(600))?;
    if st.mailer.enabled()
        && let Some(u) = repo::find_user_for_login(&st.db, &email)
            .await
            .map_err(Into::into)
            .web()?
        && !u.disabled
    {
        send_code(st, u.id, &email, CodePurpose::LoginOtp);
    }
    let step = LoginStep::Code { email, error: None };
    login_response(cx, next, step, StatusCode::OK).await
}

#[derive(Deserialize)]
pub struct VerifyForm {
    email: String,
    code: String,
    next: Option<String>,
}

#[route(POST "/login/verify")]
pub async fn login_verify(cx: &Cx, Form(f): Form<VerifyForm>) -> Result<Response> {
    let next = safe_next(f.next.as_deref());
    let st = state(cx);
    let email = f.email.trim().to_lowercase();
    super::limit(cx, "verify", 20, Duration::from_secs(600))?;
    let user = repo::find_user_for_login(&st.db, &email)
        .await
        .map_err(Into::into)
        .web()?
        .filter(|u| !u.disabled);
    let checked = match &user {
        Some(u) => check_code(st, u.id, CodePurpose::LoginOtp, &f.code)
            .await
            .is_ok(),
        None => false,
    };
    let (Some(u), true) = (user, checked) else {
        let step = LoginStep::Code {
            email,
            error: Some("That code is not valid or has expired.".into()),
        };
        return login_response(cx, next, step, StatusCode::UNPROCESSABLE_ENTITY).await;
    };
    let s = session::start(cx).await?;
    let now = now_ms();
    let expires = s
        .expires_at
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(now);
    repo::insert_session(
        &st.db,
        u.id,
        &hex(&s.token_hash[..]),
        Some("Web"),
        now,
        expires,
    )
    .await
    .map_err(Into::into)
    .web()?;
    repo::touch_user(&st.db, u.id, now)
        .await
        .map_err(Into::into)
        .web()?;
    repo::set_email_verified(&st.db, u.id, now)
        .await
        .map_err(Into::into)
        .web()?;
    see_other(next).into_response(cx)
}

#[route(POST "/logout")]
pub async fn logout(cx: &Cx) -> Result<Response> {
    if let Some(hash) = session::stop(cx).await? {
        repo::delete_session_by_hash(&state(cx).db, &hex(&hash[..]))
            .await
            .map_err(Into::into)
            .web()?;
    }
    see_other("/").into_response(cx)
}

// ---------- library ----------

async fn require_member(cx: &Cx, next: &str) -> Result<Member> {
    match member(cx).await? {
        Some(m) => Ok(m),
        None => Err(redirect(format!("/login?next={next}")).into()),
    }
}

#[page("/library")]
pub async fn library(cx: &Cx) -> Result<impl View> {
    let m = require_member(cx, "/library").await?;
    let st = state(cx);
    let scope = Scope::user(m.user_id);
    let items = scope.items(st, 200).await.web()?;
    let ids: Vec<&str> = items.iter().map(|v| v.id.as_str()).collect();
    let views = service::view_counts(st, scope.context(), &ids)
        .await
        .web()?;
    let mail = st.mailer.enabled();
    let base = st.config.public_base_url.clone();
    let now = now_ms();
    Ok(view! {
        shell(
            meta: Meta { noindex: true, ..Meta::titled("Library") },
            signed_in: true,
            <section class="library">
                <div class="library-head">
                    <h1>"Library"</h1>
                    <p class="muted">
                        "Signed in as "
                        (m.email.as_str())
                    </p>
                </div>
                if items.is_empty() {
                    <div class="empty card">
                        <h2>"No recordings yet"</h2>
                        <p>
                            "Record in the Shotglass app with Shotglass Cloud enabled. The link appears here and on your clipboard."
                        </p>
                    </div>
                }
                <div id="items" class="items">
                    #[key(v.id.clone())]
                    for v in items {
                        let n = views.get(&v.id).copied().unwrap_or(0);
                        item_card(
                            video: v,
                            views: n,
                            base: base.clone(),
                            mail: mail,
                            now: now,
                            notice: None
                        )
                    }
                </div>
            </section>
        )
    })
}

#[component]
pub async fn item_card(
    video: Video,
    views: i64,
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
    let pending = v.status != "ready";
    let thumb = format!("/v/{}/thumbnail.jpg", v.slug);
    Ok(view! {
        <article id=(card_id.as_str()) class="item card">
            <a class="thumb" href=(link.as_str())>
                if v.thumbnail_key.is_some() {
                    <img src=(thumb.as_str()) alt="" loading="lazy">
                } else {
                    <span class="thumb-empty">"▶"</span>
                }
                if v.duration_ms > 0 {
                    <span class="badge">(clock(v.duration_ms))</span>
                }
            </a>
            <div class="item-body">
                <a class="item-title" href=(link.as_str())>(v.title.as_str())</a>
                <p class="muted small">
                    (ago(v.created_at, now))
                    " · "
                    (plural(views, "view", "views"))
                    " · "
                    (visibility.label())
                    if pending {
                        " · "
                        <span class="pill">"Uploading"</span>
                    }
                </p>
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
    let st = state(cx);
    let views = service::view_counts(st, scope.context(), &[v.id.as_str()])
        .await
        .web()?
        .get(&v.id)
        .copied()
        .unwrap_or(0);
    let html = view! {
        cx =>
        item_card(
            video: v,
            views: views,
            base: st.config.public_base_url.clone(),
            mail: st.mailer.enabled(),
            now: now_ms(),
            notice: notice
        )
    }
    .single()
    .await?
    .render(cx);
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
        Err(crate::error::AppError::Invalid(msg)) => card_response(cx, &scope, v, Some(msg)).await,
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
