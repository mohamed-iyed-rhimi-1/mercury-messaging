use serde::{Deserialize, Serialize};
use std::cmp::Ordering;
use std::time::{SystemTime, UNIX_EPOCH};

/// Hybrid Logical Clock for distributed event ordering.
/// Total order: `(wall_clock_ms, counter, node_id)`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct Hlc {
    pub wall_clock_ms: u64,
    pub counter: u32,
    pub node_id: [u8; 16],
}

impl Hlc {
    #[must_use]
    pub fn now(node_id: [u8; 16]) -> Self {
        Self {
            wall_clock_ms: system_time_ms(),
            counter: 0,
            node_id,
        }
    }

    /// Advance for a local event.
    ///
    /// # Panics
    /// Panics if the logical counter overflows `u32`.
    pub fn tick(&mut self) {
        let now = system_time_ms();
        if now > self.wall_clock_ms {
            self.wall_clock_ms = now;
            self.counter = 0;
        } else {
            self.counter = self.counter.checked_add(1).expect("HLC counter overflow");
        }
    }

    /// Merge with a received remote clock.
    pub fn merge(&mut self, remote: &Self) {
        let now = system_time_ms();
        let max_wall = now.max(self.wall_clock_ms).max(remote.wall_clock_ms);

        if max_wall == self.wall_clock_ms && max_wall == remote.wall_clock_ms {
            self.counter = self.counter.max(remote.counter) + 1;
        } else if max_wall == self.wall_clock_ms {
            self.counter += 1;
        } else if max_wall == remote.wall_clock_ms {
            self.counter = remote.counter + 1;
        } else {
            // now is strictly greater
            self.counter = 0;
        }
        self.wall_clock_ms = max_wall;
    }
}

impl Ord for Hlc {
    fn cmp(&self, other: &Self) -> Ordering {
        self.wall_clock_ms
            .cmp(&other.wall_clock_ms)
            .then(self.counter.cmp(&other.counter))
            .then(self.node_id.cmp(&other.node_id))
    }
}

impl PartialOrd for Hlc {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

fn system_time_ms() -> u64 {
    u64::try_from(
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system clock before epoch")
            .as_millis(),
    )
    .expect("system time overflows u64")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn node(id: u8) -> [u8; 16] {
        let mut n = [0u8; 16];
        n[0] = id;
        n
    }

    #[test]
    fn tick_is_monotonic() {
        let mut hlc = Hlc::now(node(1));
        let before = hlc;
        hlc.tick();
        assert!(hlc > before);
    }

    #[test]
    fn rapid_ticks_increment_counter() {
        let mut hlc = Hlc::now(node(1));
        let wall = hlc.wall_clock_ms;
        // Force same millisecond by not sleeping
        hlc.tick();
        if hlc.wall_clock_ms == wall {
            assert!(hlc.counter > 0);
        }
    }

    #[test]
    fn merge_advances_past_both() {
        let mut local = Hlc::now(node(1));
        let remote = Hlc {
            wall_clock_ms: local.wall_clock_ms + 1000,
            counter: 5,
            node_id: node(2),
        };
        local.merge(&remote);
        assert!(local.wall_clock_ms >= remote.wall_clock_ms);
    }

    #[test]
    fn ordering_is_total() {
        let a = Hlc {
            wall_clock_ms: 100,
            counter: 0,
            node_id: node(1),
        };
        let b = Hlc {
            wall_clock_ms: 100,
            counter: 0,
            node_id: node(2),
        };
        // Same wall+counter, different node → still ordered
        assert_ne!(a.cmp(&b), Ordering::Equal);
    }
}
