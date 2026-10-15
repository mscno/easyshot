//! Live updates for open pages, across every server instance.
//!
//! Database triggers (`migrations/0005_live_notify.sql`, `0006_…`) `NOTIFY easyshot_live`
//! with ids and kinds only. Each process holds one `LISTEN` connection, started when the
//! first page subscribes, and fans notifications out to per-topic broadcast channels.
//! Streams re-read what changed under their own RLS context, so payloads never carry
//! content or grant access. After every (re)connect the hub sends [`Change::Resync`] to all
//! topics, covering anything missed while the connection was down.
//!
//! Topics: an item id (the watch page), [`Hub::user_topic`] (pages listing or managing one
//! owner's things: library, account) and [`Hub::session_topic`] (every stream opened with
//! that session, so revoking it signs those pages out at once).

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde::Deserialize;
use tokio::sync::broadcast;

pub const CHANNEL: &str = "easyshot_live";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Change {
    Comments,
    Reactions,
    /// Upload progress or completion, title/privacy changed: re-render the header/player.
    Video,
    /// A new unique view: re-render the counts.
    Views,
    /// Deleted: viewers see a notice.
    Gone,
    /// Owner topics: one of the owner's screenshots changed.
    Screenshots,
    /// Owner topics: a session was created, renamed or removed.
    Sessions,
    /// Owner topics: an API token was created or revoked.
    Tokens,
    /// Owner topics: the account itself (email, verification, password) changed.
    Account,
    /// Session topics: this session changed or was removed; re-check it.
    Session,
    /// The LISTEN connection (re)started; re-render everything.
    Resync,
}

/// What a subscriber receives: the change and the id of the row it concerns (empty for
/// [`Change::Resync`]), so list pages can re-render just that row.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Ping {
    pub change: Change,
    pub item: Arc<str>,
}

impl Ping {
    pub fn new(change: Change, item: &str) -> Ping {
        Ping {
            change,
            item: Arc::from(item),
        }
    }
}

/// One trigger payload; see the migrations.
#[derive(Debug, Deserialize, PartialEq)]
pub struct Notice {
    pub t: String,
    pub item: String,
    pub owner: Option<String>,
    pub ws: Option<String>,
    pub op: String,
}

impl Notice {
    /// `(topic, change)` pairs this notice fans out to.
    pub fn routes(&self) -> Vec<(String, Change)> {
        let change = match (self.t.as_str(), self.op.as_str()) {
            ("video", "delete") => Change::Gone,
            ("video", _) => Change::Video,
            ("comments", _) => Change::Comments,
            ("reactions", _) => Change::Reactions,
            ("views", _) => Change::Views,
            ("screenshot", _) => Change::Screenshots,
            ("session", _) => Change::Sessions,
            ("token", _) => Change::Tokens,
            ("user", _) => Change::Account,
            _ => return Vec::new(),
        };
        let mut out = Vec::new();
        match change {
            Change::Gone | Change::Video | Change::Comments | Change::Reactions | Change::Views => {
                out.push((self.item.clone(), change))
            }
            Change::Sessions => out.push((Hub::session_topic(&self.item), Change::Session)),
            _ => {}
        }
        if let Some(owner) = &self.owner {
            out.push((Hub::user_topic(owner), change));
        }
        if let Some(ws) = &self.ws {
            out.push((format!("ws:{ws}"), change));
        }
        out
    }
}

/// Buffered changes per topic before slow receivers lag (they then resync everything).
const CAPACITY: usize = 64;

pub struct Hub {
    channels: Mutex<HashMap<String, broadcast::Sender<Ping>>>,
    /// Open streams per key (a session), see [`Hub::admit`].
    open: Arc<Mutex<HashMap<String, usize>>>,
    /// Where to LISTEN (the app-role URL); `None` disables cross-process delivery.
    url: Option<String>,
    started: AtomicBool,
}

impl Default for Hub {
    fn default() -> Self {
        Hub::new(None)
    }
}

/// A subscription; dropping it removes the channel once nobody else listens.
pub struct Subscription {
    hub: Arc<Hub>,
    topic: String,
    pub rx: broadcast::Receiver<Ping>,
}

impl Drop for Subscription {
    fn drop(&mut self) {
        let mut map = self.hub.channels.lock().unwrap();
        if map
            .get(&self.topic)
            .is_some_and(|tx| tx.receiver_count() <= 1)
        {
            map.remove(&self.topic);
        }
    }
}

/// One admitted stream; see [`Hub::admit`].
pub struct StreamSlot {
    open: Arc<Mutex<HashMap<String, usize>>>,
    key: String,
}

impl Drop for StreamSlot {
    fn drop(&mut self) {
        let mut open = self.open.lock().unwrap();
        if let Some(n) = open.get_mut(&self.key) {
            *n -= 1;
            if *n == 0 {
                open.remove(&self.key);
            }
        }
    }
}

impl Hub {
    pub fn new(url: Option<String>) -> Hub {
        Hub {
            channels: Mutex::default(),
            open: Arc::default(),
            url,
            started: AtomicBool::new(false),
        }
    }

    pub fn user_topic(user_id: &str) -> String {
        format!("user:{user_id}")
    }

    pub fn session_topic(session_id: &str) -> String {
        format!("session:{session_id}")
    }

    /// Count one more open stream for `key`; `None` once `max` are open. The slot frees
    /// when the returned guard drops (the stream ends or the client goes away).
    pub fn admit(&self, key: &str, max: usize) -> Option<StreamSlot> {
        let mut open = self.open.lock().unwrap();
        let n = open.entry(key.to_string()).or_insert(0);
        if *n >= max {
            return None;
        }
        *n += 1;
        Some(StreamSlot {
            open: self.open.clone(),
            key: key.to_string(),
        })
    }

    /// Subscribe to a topic; the first subscription in the process starts the listener.
    pub fn subscribe(self: &Arc<Self>, topic: &str) -> Subscription {
        if let Some(url) = &self.url
            && !self.started.swap(true, Ordering::SeqCst)
        {
            tokio::spawn(listen(self.clone(), url.clone()));
        }
        let rx = self
            .channels
            .lock()
            .unwrap()
            .entry(topic.to_string())
            .or_insert_with(|| broadcast::channel(CAPACITY).0)
            .subscribe();
        Subscription {
            hub: self.clone(),
            topic: topic.to_string(),
            rx,
        }
    }

    pub fn publish(&self, topic: &str, ping: Ping) {
        if let Some(tx) = self.channels.lock().unwrap().get(topic) {
            let _ = tx.send(ping);
        }
    }

    fn publish_all(&self, change: Change) {
        let ping = Ping::new(change, "");
        for tx in self.channels.lock().unwrap().values() {
            let _ = tx.send(ping.clone());
        }
    }

    pub fn dispatch(&self, payload: &str) {
        match serde_json::from_str::<Notice>(payload) {
            Ok(n) => {
                for (topic, change) in n.routes() {
                    self.publish(&topic, Ping::new(change, &n.item));
                }
            }
            Err(e) => tracing::warn!(error = %e, "bad live notification"),
        }
    }

    pub fn watched(&self) -> usize {
        self.channels.lock().unwrap().len()
    }
}

/// Receive the next ping from either subscription (`b` is optional: anonymous streams have
/// no session topic). `Lagged` and `Closed` are reported as a resync / `None`.
pub async fn next_ping(a: &mut Subscription, b: Option<&mut Subscription>) -> Option<Ping> {
    let r = match b {
        Some(b) => tokio::select! {
            r = a.rx.recv() => r,
            r = b.rx.recv() => r,
        },
        None => a.rx.recv().await,
    };
    match r {
        Ok(p) => Some(p),
        Err(broadcast::error::RecvError::Lagged(_)) => Some(Ping::new(Change::Resync, "")),
        Err(broadcast::error::RecvError::Closed) => None,
    }
}

/// A ping already queued on either subscription, without waiting.
pub fn try_ping(a: &mut Subscription, b: Option<&mut Subscription>) -> Option<Ping> {
    let take = |s: &mut Subscription| match s.rx.try_recv() {
        Ok(p) => Some(p),
        Err(broadcast::error::TryRecvError::Lagged(_)) => Some(Ping::new(Change::Resync, "")),
        Err(_) => None,
    };
    take(a).or_else(|| b.and_then(take))
}

/// Hold a LISTEN session for the life of the process, reconnecting with backoff.
async fn listen(hub: Arc<Hub>, url: String) {
    let mut backoff = Duration::from_millis(250);
    loop {
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
        match crate::pg::connect(&url, Some(tx)).await {
            Ok(client) => match client.batch_execute(&format!("LISTEN {CHANNEL}")).await {
                Ok(()) => {
                    backoff = Duration::from_millis(250);
                    hub.publish_all(Change::Resync);
                    while let Some(n) = rx.recv().await {
                        hub.dispatch(n.payload());
                    }
                    tracing::warn!("live listener disconnected; reconnecting");
                }
                Err(e) => tracing::warn!(error = %e, "LISTEN failed"),
            },
            Err(e) => tracing::warn!(error = %e, "live listener could not connect"),
        }
        tokio::time::sleep(backoff).await;
        backoff = (backoff * 2).min(Duration::from_secs(30));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn c(p: Ping) -> Change {
        p.change
    }

    #[tokio::test]
    async fn fan_out_and_cleanup() {
        let hub = Arc::new(Hub::default());
        hub.publish("v", Ping::new(Change::Comments, "v")); // nobody listening: no channel
        assert_eq!(hub.watched(), 0);
        let mut a = hub.subscribe("v");
        let mut b = hub.subscribe("v");
        hub.publish("v", Ping::new(Change::Reactions, "v"));
        assert_eq!(c(a.rx.recv().await.unwrap()), Change::Reactions);
        assert_eq!(c(b.rx.recv().await.unwrap()), Change::Reactions);
        drop(a);
        assert_eq!(hub.watched(), 1);
        drop(b);
        assert_eq!(hub.watched(), 0);
    }

    #[tokio::test]
    async fn routes_notifications_to_item_owner_and_session_topics() {
        let hub = Arc::new(Hub::default());
        let mut item = hub.subscribe("v1");
        let mut owner = hub.subscribe(&Hub::user_topic("u1"));
        let mut session = hub.subscribe(&Hub::session_topic("s1"));
        hub.dispatch(r#"{"t":"video","item":"v1","owner":"u1","ws":null,"op":"update"}"#);
        assert_eq!(c(item.rx.recv().await.unwrap()), Change::Video);
        let p = owner.rx.recv().await.unwrap();
        assert_eq!((p.change, &*p.item), (Change::Video, "v1"));
        hub.dispatch(r#"{"t":"comments","item":"v1","owner":"u1","ws":null,"op":"insert"}"#);
        assert_eq!(c(item.rx.recv().await.unwrap()), Change::Comments);
        assert_eq!(c(owner.rx.recv().await.unwrap()), Change::Comments);
        hub.dispatch(r#"{"t":"video","item":"v1","owner":"u1","ws":null,"op":"delete"}"#);
        assert_eq!(c(item.rx.recv().await.unwrap()), Change::Gone);
        assert_eq!(c(owner.rx.recv().await.unwrap()), Change::Gone);
        hub.dispatch(r#"{"t":"screenshot","item":"s1","owner":"u1","ws":null,"op":"insert"}"#);
        assert_eq!(c(owner.rx.recv().await.unwrap()), Change::Screenshots);
        hub.dispatch(r#"{"t":"session","item":"s1","owner":"u1","ws":null,"op":"delete"}"#);
        assert_eq!(c(session.rx.recv().await.unwrap()), Change::Session);
        assert_eq!(c(owner.rx.recv().await.unwrap()), Change::Sessions);
        hub.dispatch(r#"{"t":"token","item":"t1","owner":"u1","ws":null,"op":"insert"}"#);
        assert_eq!(c(owner.rx.recv().await.unwrap()), Change::Tokens);
        hub.dispatch("not json");
        assert!(item.rx.try_recv().is_err());
    }

    #[test]
    fn admits_a_bounded_number_of_streams() {
        let hub = Hub::default();
        let a = hub.admit("s", 2).unwrap();
        let _b = hub.admit("s", 2).unwrap();
        assert!(hub.admit("s", 2).is_none());
        drop(a);
        assert!(hub.admit("s", 2).is_some());
    }
}
