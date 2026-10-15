//! Small in-memory fixed-window rate limiter for web writes (comments, reactions, unlock
//! attempts, email sends). Per instance, which is enough to blunt abuse; the database
//! limits on login codes stay authoritative for authentication.

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

/// Entries are pruned once the map grows past this.
const PRUNE_AT: usize = 10_000;

#[derive(Default)]
pub struct RateLimiter {
    windows: Mutex<HashMap<String, (Instant, u32)>>,
}

impl RateLimiter {
    /// Count one hit for `key`; false when `limit` hits already happened in this `window`.
    pub fn allow(&self, key: &str, limit: u32, window: Duration) -> bool {
        let now = Instant::now();
        let mut map = self.windows.lock().unwrap();
        if map.len() > PRUNE_AT {
            map.retain(|_, (start, _)| now.duration_since(*start) < Duration::from_secs(3600));
        }
        let entry = map.entry(key.to_string()).or_insert((now, 0));
        if now.duration_since(entry.0) >= window {
            *entry = (now, 0);
        }
        if entry.1 >= limit {
            return false;
        }
        entry.1 += 1;
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn limits_per_key_and_resets() {
        let l = RateLimiter::default();
        let w = Duration::from_millis(50);
        assert!(l.allow("a", 2, w) && l.allow("a", 2, w));
        assert!(!l.allow("a", 2, w));
        assert!(l.allow("b", 2, w));
        std::thread::sleep(Duration::from_millis(60));
        assert!(l.allow("a", 2, w));
    }
}
