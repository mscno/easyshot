//! In-process fan-out of video changes to open watch pages.
//!
//! Each watch page holds one Datastar SSE stream. Writers publish a small [`Change`] after
//! committing; the stream re-reads the affected region and patches it. Channels exist only
//! while someone is watching. Across several server instances a page also resyncs on a
//! timer (see `web::live`), so a change made on another instance shows up within seconds.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use tokio::sync::broadcast;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Change {
    Comments,
    Reactions,
    /// Upload finished, title/privacy changed, views moved: re-render the header/player.
    Video,
    /// Deleted or made unavailable: viewers should reload.
    Gone,
}

/// Buffered changes per video before slow receivers lag (they then resync everything).
const CAPACITY: usize = 32;

#[derive(Default)]
pub struct Hub {
    channels: Mutex<HashMap<String, broadcast::Sender<Change>>>,
}

/// A subscription; dropping it removes the channel once nobody else listens.
pub struct Subscription {
    hub: Arc<Hub>,
    video_id: String,
    pub rx: broadcast::Receiver<Change>,
}

impl Drop for Subscription {
    fn drop(&mut self) {
        let mut map = self.hub.channels.lock().unwrap();
        if map
            .get(&self.video_id)
            .is_some_and(|tx| tx.receiver_count() <= 1)
        {
            map.remove(&self.video_id);
        }
    }
}

impl Hub {
    pub fn subscribe(self: &Arc<Self>, video_id: &str) -> Subscription {
        let rx = self
            .channels
            .lock()
            .unwrap()
            .entry(video_id.to_string())
            .or_insert_with(|| broadcast::channel(CAPACITY).0)
            .subscribe();
        Subscription {
            hub: self.clone(),
            video_id: video_id.to_string(),
            rx,
        }
    }

    pub fn publish(&self, video_id: &str, change: Change) {
        if let Some(tx) = self.channels.lock().unwrap().get(video_id) {
            let _ = tx.send(change);
        }
    }

    pub fn watched(&self) -> usize {
        self.channels.lock().unwrap().len()
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
}
