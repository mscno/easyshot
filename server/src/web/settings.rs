//! `/account`: email and verification, password, signed-in devices (Mac app and browsers),
//! API tokens and account deletion. The page keeps one live stream: devices signing in or
//! out, tokens created or revoked and verification changes appear in every open tab, and
//! revoking a session signs out the pages that session has open.

use std::collections::VecDeque;
use std::future::Future;
use std::time::{Duration, Instant};

use futures_util::{Stream, stream};
use serde::Deserialize;
use topcoat::{
    Result,
    context::Cx,
    datastar::{PatchElements, datastar_request},
    router::{
        StatusCode,
        content::{
            Form,
            sse::{Event, KeepAlive, Sse},
        },
        error::{redirect, see_other},
        path_param, query_params,
        response::{IntoResponse, Response},
        route,
    },
    session,
    view::{View, ViewExt, component, view},
};
use uuid::Uuid;

use super::auth::{password_problem, throttle};
use super::layout::{Meta, ago, shell};
use super::{Member, WebResult, admit_stream, member, signed_out_patch, start_session, state};
use crate::auth::{
    API_PREFIX, Bucket, generate_token, hash_password_blocking, verify_password_blocking,
};
use crate::mailer::CodePurpose;
use crate::repo::{self, SessionRow, TokenRow, now_ms};
use crate::routes::codes::{check_code, send_code};
use crate::state::AppState;
use crate::video::live::{Change, Hub, StreamSlot, Subscription, next_ping, try_ping};

async fn require(cx: &Cx) -> Result<Member> {
    match member(cx).await? {
        Some(m) => Ok(m),
        None => Err(redirect("/login?next=/account").into()),
    }
}

/// Plain form posts return to the page; Datastar posts get patches.
fn back(cx: &Cx) -> Result<Response> {
    see_other("/account").into_response(cx)
}

const ENHANCE: &str = "{contentType: 'form', retry: 'never', retryMaxCount: 0}";

fn enhance(url: &str) -> String {
    format!("@post('{url}', {ENHANCE})")
}

// ---------- regions ----------

#[component]
pub async fn profile_region(
    email: String,
    verified: bool,
    notice: Option<String>,
) -> Result<impl View> {
    let send_js = enhance("/account/verify/send");
    let verify_js = enhance("/account/verify");
    Ok(view! {
        <section id="profile" class="card">
            <h2>"Account"</h2>
            <p>
                <strong>(email.as_str())</strong>
                " "
                if verified {
                    <span class="pill ok">"Verified"</span>
                } else {
                    <span class="pill">"Not verified"</span>
                }
            </p>
            match notice {
                Some(n) => <p class="notice" role="status">(n)</p>,
                None => "",
            }
            if !verified {
                <p class="muted small">
                    "Verify your email to upload recordings from the Mac app."
                </p>
                <form
                    method="post"
                    action="/account/verify/send"
                    class="row"
                    data-on:submit=(send_js.as_str())
                >
                    <button type="submit" class="button small">
                        "Email me a code"
                    </button>
                </form>
                <form
                    method="post"
                    action="/account/verify"
                    class="row"
                    data-on:submit=(verify_js.as_str())
                >
                    <label class="sr-only" for="verify-code">"Code"</label>
                    <input
                        id="verify-code"
                        name="code"
                        inputmode="numeric"
                        pattern="[0-9]{6}"
                        maxlength="6"
                        placeholder="6-digit code"
                        autocomplete="one-time-code"
                        required=""
                    >
                    <button type="submit" class="button small">"Verify"</button>
                </form>
            }
        </section>
    })
}

#[component]
pub async fn sessions_region(rows: Vec<SessionRow>, current: Uuid, now: i64) -> Result<impl View> {
    let others = rows.iter().filter(|r| r.id != current).count();
    let others_js = enhance("/account/sessions/revoke-others");
    Ok(view! {
        <section id="sessions" class="card">
            <h2>"Signed-in devices"</h2>
            <ul class="list">
                #[key(r.id.to_string())]
                for r in rows {
                    let this = r.id == current;
                    let url = format!("/account/sessions/{}/revoke", r.id);
                    let js = enhance(&url);
                    let li_id = format!("session-{}", r.id);
                    <li id=(li_id.as_str()) class="list-row">
                        <div>
                            <strong>
                                (r
                                    .device_name
                                    .clone()
                                    .unwrap_or_else(|| "Unknown device".into()))
                            </strong>
                            if this {
                                " "
                                <span class="pill ok">"This browser"</span>
                            }
                            <p class="muted small">
                                "Signed in "
                                (ago(r.created_at, now))
                                " · last used "
                                (ago(r.last_used_at, now))
                            </p>
                        </div>
                        if !this {
                            <form
                                method="post"
                                action=(url.as_str())
                                data-on:submit=(js.as_str())
                            >
                                <button type="submit" class="button small danger">
                                    "Sign out"
                                </button>
                            </form>
                        }
                    </li>
                }
            </ul>
            if others > 0 {
                <form
                    method="post"
                    action="/account/sessions/revoke-others"
                    data-on:submit=(others_js.as_str())
                >
                    <button type="submit" class="button small">
                        "Sign out all other devices"
                    </button>
                </form>
            }
        </section>
    })
}

#[component]
pub async fn tokens_region(rows: Vec<TokenRow>, now: i64) -> Result<impl View> {
    let create_js = enhance("/account/tokens");
    Ok(view! {
        <section id="tokens" class="card">
            <h2>"API tokens"</h2>
            <p class="muted small">
                "For agents, scripts and CI. A token acts as you; revoke it when it is no longer needed."
            </p>
            if rows.is_empty() {
                <p class="muted">"No tokens."</p>
            } else {
                <ul class="list">
                    #[key(t.id.to_string())]
                    for t in rows {
                        let url = format!("/account/tokens/{}/revoke", t.id);
                        let js = enhance(&url);
                        let li_id = format!("token-{}", t.id);
                        <li id=(li_id.as_str()) class="list-row">
                            <div>
                                <strong>(t.name.as_str())</strong>
                                <p class="muted small">
                                    "Created "
                                    (ago(t.created_at, now))
                                    " · "
                                    (match t.last_used_at {
                                        Some(u) => format!("last used {}", ago(u, now)),
                                        None => "never used".into(),
                                    })
                                </p>
                            </div>
                            <form
                                method="post"
                                action=(url.as_str())
                                data-on:submit=(js.as_str())
                            >
                                <button type="submit" class="button small danger">
                                    "Revoke"
                                </button>
                            </form>
                        </li>
                    }
                </ul>
            }
            <form
                method="post"
                action="/account/tokens"
                class="row"
                data-on:submit=(create_js.as_str())
            >
                <label class="sr-only" for="token-name">"Token name"</label>
                <input
                    id="token-name"
                    name="name"
                    maxlength="100"
                    placeholder="e.g. Claude Code on my laptop"
                    required=""
                >
                <button type="submit" class="button small">"Create token"</button>
            </form>
        </section>
    })
}

/// Shown once, right after creation; never re-rendered by the live stream.
#[component]
pub async fn token_created(token: Option<String>) -> Result<impl View> {
    Ok(view! {
        <div id="token-created">
            if let Some(t) = token.as_deref() {
                <div class="notice" role="status">
                    <p>
                        <strong>
                            "Copy your new token now. It is not shown again."
                        </strong>
                    </p>
                    <p class="row">
                        <code class="token">(t)</code>
                        <button type="button" class="button small" data-copy=(t)>
                            "Copy"
                        </button>
                    </p>
                </div>
            }
        </div>
    })
}

#[derive(Default)]
struct Notices {
    profile: Option<String>,
    password: Option<String>,
    token: Option<String>,
    delete: Option<String>,
}

async fn account_view(cx: &Cx, m: Member, n: Notices) -> Result<String> {
    let st = state(cx);
    let now = now_ms();
    let sessions = repo::list_sessions(&st.db, m.user_id, now)
        .await
        .map_err(Into::into)
        .web()?;
    let tokens = repo::list_api_tokens(&st.db, m.user_id)
        .await
        .map_err(Into::into)
        .web()?;
    let live_expr =
        format!("@get('/account/live?since={now}', {{retry: 'always', retryMaxCount: 1000}})");
    let Notices {
        profile,
        password,
        token,
        delete,
    } = n;
    Ok(view! {
        cx =>
        shell(
            meta: Meta { noindex: true, ..Meta::titled("Account") },
            signed_in: true,
            <div id="account" class="account" data-init=(live_expr.as_str())>
                profile_region(
                    email: m.email.clone(),
                    verified: m.email_verified,
                    notice: profile
                )
                <section id="password-card" class="card">
                    <h2>"Password"</h2>
                    match password {
                        Some(p) => <p class="notice" role="status">(p)</p>,
                        None => "",
                    }
                    <form method="post" action="/account/password" class="stack">
                        <input
                            type="hidden"
                            name="username"
                            value=(m.email.as_str())
                            autocomplete="username"
                        >
                        <label for="current">"Current password"</label>
                        <input
                            id="current"
                            name="current"
                            type="password"
                            required=""
                            autocomplete="current-password"
                        >
                        <label for="new-password">"New password"</label>
                        <input
                            id="new-password"
                            name="password"
                            type="password"
                            minlength="10"
                            maxlength="256"
                            required=""
                            autocomplete="new-password"
                        >
                        <button type="submit" class="button">"Change password"</button>
                        <p class="muted small">
                            "Other devices are signed out when you change it."
                        </p>
                    </form>
                </section>
                sessions_region(rows: sessions, current: m.session_id, now: now)
                token_created(token: token)
                tokens_region(rows: tokens, now: now)
                <section id="danger" class="card danger-zone">
                    <h2>"Delete account"</h2>
                    <p class="muted small">
                        "Deletes your recordings, screenshots, links, comments on your recordings and tokens. This cannot be undone."
                    </p>
                    match delete {
                        Some(d) => <p class="notice error" role="alert">(d)</p>,
                        None => "",
                    }
                    <form method="post" action="/account/delete" class="stack">
                        <label for="confirm">"Type your email to confirm"</label>
                        <input
                            id="confirm"
                            name="confirm"
                            type="email"
                            required=""
                            autocomplete="off"
                        >
                        <button type="submit" class="button danger">
                            "Delete my account"
                        </button>
                    </form>
                </section>
            </div>
        )
    }
    .single()
    .await?
    .render(cx))
}

fn page_response(html: String, status: StatusCode) -> Response {
    let mut res = Response::new(html.into());
    *res.status_mut() = status;
    res.headers_mut().insert(
        topcoat::router::header::CONTENT_TYPE,
        topcoat::router::HeaderValue::from_static("text/html; charset=utf-8"),
    );
    res
}

#[query_params]
pub struct AccountQuery {
    password: Option<String>,
}

#[route(GET "/account")]
pub async fn account(cx: &Cx) -> Result<Response> {
    let m = require(cx).await?;
    let changed = query_params::<AccountQuery>(cx)
        .ok()
        .and_then(|q| q.password.clone())
        .is_some_and(|p| p == "changed");
    let n = Notices {
        password: changed.then(|| "Password changed. Other devices were signed out.".into()),
        ..Notices::default()
    };
    Ok(page_response(account_view(cx, m, n).await?, StatusCode::OK))
}

async fn patch_profile(
    cx: &Cx,
    m: &Member,
    verified: bool,
    notice: Option<String>,
) -> Result<Response> {
    if !datastar_request(cx) {
        return back(cx);
    }
    let email = m.email.clone();
    let html = view! {
        cx =>
        profile_region(email: email, verified: verified, notice: notice)
    }
    .single()
    .await?
    .render(cx);
    PatchElements::new(html).into_response(cx)
}

#[route(POST "/account/verify/send")]
pub async fn verify_send(cx: &Cx) -> Result<Response> {
    let m = require(cx).await?;
    let st = state(cx);
    throttle(cx, Bucket::CodeRequest)?;
    let notice = if !st.mailer.enabled() {
        "Email is not configured on this server."
    } else {
        send_code(st, m.user_id, &m.email, CodePurpose::VerifyEmail);
        "A code is on its way."
    };
    patch_profile(cx, &m, m.email_verified, Some(notice.into())).await
}

#[derive(Deserialize)]
pub struct CodeForm {
    code: String,
}

#[route(POST "/account/verify")]
pub async fn verify(cx: &Cx, Form(f): Form<CodeForm>) -> Result<Response> {
    let m = require(cx).await?;
    let st = state(cx);
    // From an existing session, so not a claim: credentials stay as they are.
    throttle(cx, Bucket::CodeVerify)?;
    if check_code(st, m.user_id, CodePurpose::VerifyEmail, &f.code)
        .await
        .is_err()
    {
        let notice = Some("That code is not valid or has expired.".into());
        return patch_profile(cx, &m, false, notice).await;
    }
    repo::set_email_verified(&st.db, m.user_id, now_ms())
        .await
        .map_err(Into::into)
        .web()?;
    patch_profile(cx, &m, true, Some("Email verified.".into())).await
}

#[derive(Deserialize)]
pub struct PasswordForm {
    current: String,
    password: String,
}

#[route(POST "/account/password")]
pub async fn change_password(cx: &Cx, Form(f): Form<PasswordForm>) -> Result<Response> {
    let m = require(cx).await?;
    let st = state(cx);
    super::limit(cx, "password", 10, Duration::from_secs(600))?;
    let fail = |msg: String| {
        let m = m.clone();
        async move {
            let n = Notices {
                password: Some(msg),
                ..Notices::default()
            };
            Ok::<Response, topcoat::Error>(page_response(
                account_view(cx, m, n).await?,
                StatusCode::UNPROCESSABLE_ENTITY,
            ))
        }
    };
    if let Some(p) = password_problem(&f.password) {
        return fail(p).await;
    }
    let Some(u) = repo::find_user_for_login(&st.db, &m.email)
        .await
        .map_err(Into::into)
        .web()?
    else {
        return Err(redirect("/login").into());
    };
    if !verify_password_blocking(f.current, u.password_hash)
        .await
        .web()?
    {
        return fail("Your current password is not correct.".into()).await;
    }
    let hash = hash_password_blocking(f.password).await.web()?;
    repo::set_password(&st.db, m.user_id, &hash, now_ms())
        .await
        .map_err(Into::into)
        .web()?;
    repo::delete_user_sessions(&st.db, m.user_id)
        .await
        .map_err(Into::into)
        .web()?;
    // A new token for this browser too: whoever held the old one is out.
    start_session(cx, m.user_id).await?;
    see_other("/account?password=changed").into_response(cx)
}

async fn patch_sessions(cx: &Cx, m: &Member) -> Result<Response> {
    if !datastar_request(cx) {
        return back(cx);
    }
    let html = render_sessions(cx, state(cx), m).await?;
    PatchElements::new(html).into_response(cx)
}

async fn render_sessions(cx: &Cx, st: &AppState, m: &Member) -> Result<String> {
    let now = now_ms();
    let rows = repo::list_sessions(&st.db, m.user_id, now)
        .await
        .map_err(Into::into)
        .web()?;
    let current = m.session_id;
    Ok(
        view! { cx => sessions_region(rows: rows, current: current, now: now) }
            .single()
            .await?
            .render(cx),
    )
}

async fn render_tokens(cx: &Cx, st: &AppState, m: &Member) -> Result<String> {
    let rows = repo::list_api_tokens(&st.db, m.user_id)
        .await
        .map_err(Into::into)
        .web()?;
    let now = now_ms();
    Ok(view! { cx => tokens_region(rows: rows, now: now) }
        .single()
        .await?
        .render(cx))
}

path_param!(pub id);

#[route(POST "/account/sessions/{id}/revoke")]
pub async fn revoke_session(cx: &Cx) -> Result<Response> {
    let m = require(cx).await?;
    let id =
        Uuid::parse_str(path_param::<Id>(cx)).map_err(|_| topcoat::router::error::not_found())?;
    // This browser signs out with "Sign out" instead.
    if id != m.session_id {
        repo::delete_user_session(&state(cx).db, m.user_id, id)
            .await
            .map_err(Into::into)
            .web()?;
    }
    patch_sessions(cx, &m).await
}

#[route(POST "/account/sessions/revoke-others")]
pub async fn revoke_others(cx: &Cx) -> Result<Response> {
    let m = require(cx).await?;
    repo::delete_other_sessions(&state(cx).db, m.user_id, m.session_id)
        .await
        .map_err(Into::into)
        .web()?;
    patch_sessions(cx, &m).await
}

#[derive(Deserialize)]
pub struct TokenForm {
    name: String,
}

#[route(POST "/account/tokens")]
pub async fn create_token(cx: &Cx, Form(f): Form<TokenForm>) -> Result<Response> {
    let m = require(cx).await?;
    let st = state(cx);
    super::limit(cx, "token", 20, Duration::from_secs(3600))?;
    // Like `POST /v1/tokens`: no lasting credentials before the mailbox is proven.
    if st.mailer.enabled() && !m.email_verified {
        let notice = "Confirm your email address before creating API tokens.";
        if datastar_request(cx) {
            return patch_profile(cx, &m, false, Some(notice.into())).await;
        }
        let n = Notices {
            profile: Some(notice.into()),
            ..Notices::default()
        };
        return Ok(page_response(
            account_view(cx, m, n).await?,
            StatusCode::FORBIDDEN,
        ));
    }
    let name = f.name.trim().to_string();
    if name.is_empty() || name.chars().count() > 100 {
        return Err(topcoat::router::error::bad_request("name must be 1-100 characters").into());
    }
    let (token, hash) = generate_token(API_PREFIX);
    repo::insert_api_token(&st.db, Uuid::new_v4(), m.user_id, &name, &hash, now_ms())
        .await
        .map_err(Into::into)
        .web()?;
    if !datastar_request(cx) {
        let n = Notices {
            token: Some(token),
            ..Notices::default()
        };
        return Ok(page_response(account_view(cx, m, n).await?, StatusCode::OK));
    }
    let shown = view! { cx => token_created(token: Some(token)) }
        .single()
        .await?
        .render(cx);
    let list = render_tokens(cx, st, &m).await?;
    let events = vec![
        Ok::<Event, topcoat::Error>(PatchElements::new(shown).into()),
        Ok(PatchElements::new(list).into()),
    ];
    Sse::new(stream::iter(events)).into_response(cx)
}

#[route(POST "/account/tokens/{id}/revoke")]
pub async fn revoke_token(cx: &Cx) -> Result<Response> {
    let m = require(cx).await?;
    let st = state(cx);
    let id =
        Uuid::parse_str(path_param::<Id>(cx)).map_err(|_| topcoat::router::error::not_found())?;
    repo::revoke_api_token(&st.db, id, m.user_id, now_ms())
        .await
        .map_err(Into::into)
        .web()?;
    if !datastar_request(cx) {
        return back(cx);
    }
    let list = render_tokens(cx, st, &m).await?;
    PatchElements::new(list).into_response(cx)
}

#[derive(Deserialize)]
pub struct DeleteForm {
    confirm: String,
}

#[route(POST "/account/delete")]
pub async fn delete_account(cx: &Cx, Form(f): Form<DeleteForm>) -> Result<Response> {
    let m = require(cx).await?;
    let st = state(cx);
    if f.confirm.trim().to_lowercase() != m.email {
        let n = Notices {
            delete: Some("Type your email address exactly to confirm.".into()),
            ..Notices::default()
        };
        return Ok(page_response(
            account_view(cx, m, n).await?,
            StatusCode::UNPROCESSABLE_ENTITY,
        ));
    }
    let _ = session::stop(cx).await?;
    crate::routes::internal::purge_account(st, m.user_id)
        .await
        .web()?;
    see_other("/").into_response(cx)
}

// ---------- live ----------

#[derive(Default, Clone, Copy)]
struct Dirty {
    profile: bool,
    sessions: bool,
    tokens: bool,
}

struct Live {
    cx: Cx,
    st: AppState,
    session_id: Uuid,
    user: Subscription,
    session: Subscription,
    _slot: StreamSlot,
    queue: VecDeque<Event>,
    done: bool,
    opened: Instant,
}

impl Live {
    async fn render(&mut self, d: Dirty) -> Result<()> {
        // Re-authorize on every render: a revoked session stops here.
        let Some(m) = member(&self.cx)
            .await?
            .filter(|m| m.session_id == self.session_id)
        else {
            self.done = true;
            self.queue.push_back(signed_out_patch("/account").into());
            return Ok(());
        };
        let (cx, st) = (&self.cx, &self.st);
        let mut out = Vec::new();
        if d.profile {
            let (email, verified) = (m.email.clone(), m.email_verified);
            out.push(
                view! {
                    cx =>
                    profile_region(email: email, verified: verified, notice: None)
                }
                .single()
                .await?
                .render(cx),
            );
        }
        if d.sessions {
            out.push(render_sessions(cx, st, &m).await?);
        }
        if d.tokens {
            out.push(render_tokens(cx, st, &m).await?);
        }
        self.queue
            .extend(out.into_iter().map(|h| PatchElements::new(h).into()));
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
                    Change::Account => d.profile = true,
                    Change::Sessions => d.sessions = true,
                    Change::Tokens => d.tokens = true,
                    // Our own session changed or the listener reconnected: re-check it all.
                    Change::Session | Change::Resync => {
                        d = Dirty {
                            profile: true,
                            sessions: true,
                            tokens: true,
                        }
                    }
                    _ => {}
                }
                ping = try_ping(&mut self.user, Some(&mut self.session));
            }
            if !(d.profile || d.sessions || d.tokens) {
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

#[route(GET "/account/live")]
pub async fn live(cx: &Cx) -> Result<Sse<impl Stream<Item = Result<Event>> + Send + use<>>> {
    let m = match member(cx).await? {
        Some(m) => m,
        None => return Err(topcoat::router::error::unauthorized().into()),
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
        session_id: m.session_id,
        _slot: slot,
        queue: VecDeque::new(),
        done: false,
        opened: Instant::now(),
    };
    if now_ms() - since > 5_000 {
        live.render(Dirty {
            profile: true,
            sessions: true,
            tokens: true,
        })
        .await?;
    }
    let events = stream::unfold(live, |l| l.next());
    Ok(Sse::new(events).keep_alive(KeepAlive::new().interval(Duration::from_secs(15))))
}
