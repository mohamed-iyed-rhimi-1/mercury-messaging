use crate::hlc::Hlc;
use crate::traits::Mergeable;
use serde::{Deserialize, Serialize};

/// Last-Writer-Wins Register. Used for user profile fields, channel names.
/// Higher HLC timestamp wins on merge.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LwwRegister<T> {
    value: T,
    timestamp: Hlc,
}

impl<T> LwwRegister<T> {
    #[must_use]
    pub fn new(value: T, timestamp: Hlc) -> Self {
        Self { value, timestamp }
    }

    /// Update value only if `timestamp` is strictly newer.
    pub fn set(&mut self, value: T, timestamp: Hlc) {
        if timestamp > self.timestamp {
            self.value = value;
            self.timestamp = timestamp;
        }
    }

    #[must_use]
    pub fn get(&self) -> &T {
        &self.value
    }

    #[must_use]
    pub fn timestamp(&self) -> &Hlc {
        &self.timestamp
    }
}

impl<T: Clone + PartialEq> Mergeable for LwwRegister<T> {
    fn merge(&mut self, other: &Self) {
        if other.timestamp > self.timestamp {
            self.value = other.value.clone();
            self.timestamp = other.timestamp;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hlc(wall: u64, counter: u32, node: u8) -> Hlc {
        let mut node_id = [0u8; 16];
        node_id[0] = node;
        Hlc {
            wall_clock_ms: wall,
            counter,
            node_id,
        }
    }

    #[test]
    fn newer_timestamp_wins() {
        let mut reg = LwwRegister::new("old", hlc(100, 0, 1));
        reg.set("new", hlc(200, 0, 1));
        assert_eq!(*reg.get(), "new");
    }

    #[test]
    fn older_timestamp_ignored() {
        let mut reg = LwwRegister::new("current", hlc(200, 0, 1));
        reg.set("stale", hlc(100, 0, 1));
        assert_eq!(*reg.get(), "current");
    }

    #[test]
    fn merge_takes_newer() {
        let mut a = LwwRegister::new("a", hlc(100, 0, 1));
        let b = LwwRegister::new("b", hlc(200, 0, 2));
        a.merge(&b);
        assert_eq!(*a.get(), "b");
    }
}
