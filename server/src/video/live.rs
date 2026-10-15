//! Live updates for open pages, across every server instance.
//!
//! Database triggers (`migrations/0005_live_notify.sql`) `NOTIFY easyshot_live` with ids and
//! kinds only. Each process holds one `LISTEN` connection, started when the first page
//! subscribes, and fans notifications out to per-topic broadcast channels. A topic is an
//! item id (the watch page) or [`Hub::user_topic`] (pages listing one owner's items).
//! Streams re-read what changed under their own RLS context, so payloads never carry
//! content or grant access. After every (re)connect the hub sends [`Change::Resync`] to all
//! topics, covering anything missed while the connection was down.

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
    /// Upload finished, title/privacy changed: re-render the header/player.
    Video,
    /// A new unique view: re-render the counts.
    Views,
    /// Deleted: viewers see a notice.
    Gone,
    /// Owner topics: one of the owner's screenshots changed.
    Screenshots,
    /// The LISTEN connection (re)started; re-render everything.
    Resync,
}

/// One trigger payload; see the migration.
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
        let item = match (self.t.as_str(), self.op.as_str()) {
            ("video", "delete") => Some(Change::Gone),
            ("video", _) => Some(Change::Video),
            ("comments", _) => Some(Change::Comments),
            ("reactions", _) => Some(Change::Reactions),
            ("views", _) => Some(Change::Views),
            _ => None,
        };
        let mut out: Vec<(String, Change)> =
            item.map(|c| (self.item.clone(), c)).into_iter().collect();
        if let Some(owner) = &self.owner {
            let c = if self.t == "screenshot" {
                Change::Screenshots
            } else {
                Change::Video
            };
            out.push((Hub::user_topic(owner), c));
        }
        if let Some(ws) = &self.ws {
            out.push((format!("ws:{ws}"), item.unwrap_or(Change::Screenshots)));
        }
        out
    }
}

/// Buffered changes per topic before slow receivers lag (they then resync everything).
const CAPACITY: usize = 64;

pub struct Hub {
    channels: Mutex<HashMap<String, broadcast::Sender<Change>>>,
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
    pub rx: broadcast::Receiver<Change>,
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

impl Hub {
    pub fn new(url: Option<String>) -> Hub {
        Hub {
            channels: Mutex::default(),
            url,
            started: AtomicBool::new(false),
        }
    }

    pub fn user_topic(user_id: &str) -> String {
        format!("user:{user_id}")
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

    pub fn publish(&self, topic: &str, change: Change) {
        if let Some(tx) = self.channels.lock().unwrap().get(topic) {
            let _ = tx.send(change);
        }
    }

    fn publish_all(&self, change: Change) {
        for tx in self.channels.lock().unwrap().values() {
            let _ = tx.send(change);
        }
    }

    pub fn dispatch(&self, payload: &str) {
        match serde_json::from_str::<Notice>(payload) {
            Ok(n) => {
                for (topic, change) in n.routes() {
                    self.publish(&topic, change);
                }
            }
            Err(e) => tracing::warn!(error = %e, "bad live notification"),
        }
    }

    pub fn watched(&self) -> usize {
        self.channels.lock().unwrap().len()
    }
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

    #[tokio::test]
    async fn fan_out_and_cleanup() {
        let hub = Arc::new(Hub::default());
        hub.publish("v", Change::Comments); // nobody listening: no channel
        assert_eq!(hub.watched(), 0);
        let mut a = hub.subscribe("v");
        let mut b = hub.subscribe("v");
        hub.publish("v", Change::Reactions);
        assert_eq!(a.rx.recv().await.unwrap(), Change::Reactions);
        assert_eq!(b.rx.recv().await.unwrap(), Change::Reactions);
        drop(a);
        assert_eq!(hub.watched(), 1);
        drop(b);
        assert_eq!(hub.watched(), 0);
    }

    #[tokio::test]
    async fn routes_notifications_to_item_and_owner_topics() {
        let hub = Arc::new(Hub::default());
        let mut item = hub.subscribe("v1");
        let mut owner = hub.subscribe(&Hub::user_topic("u1"));
        hub.dispatch(r#"{"t":"video","item":"v1","owner":"u1","ws":null,"op":"update"}"#);
        assert_eq!(item.rx.recv().await.unwrap(), Change::Video);
        assert_eq!(owner.rx.recv().await.unwrap(), Change::Video);
        hub.dispatch(r#"{"t":"comments","item":"v1","owner":null,"ws":null,"op":"insert"}"#);
        assert_eq!(item.rx.recv().await.unwrap(), Change::Comments);
        hub.dispatch(r#"{"t":"video","item":"v1","owner":"u1","ws":null,"op":"delete"}"#);
        assert_eq!(item.rx.recv().await.unwrap(), Change::Gone);
        hub.dispatch(r#"{"t":"screenshot","item":"s1","owner":"u1","ws":null,"op":"insert"}"#);
        assert_eq!(owner.rx.recv().await.unwrap(), Change::Video);
        assert_eq!(owner.rx.recv().await.unwrap(), Change::Screenshots);
        hub.dispatch("not json");
        assert!(item.rx.try_recv().is_err());
    }
}
