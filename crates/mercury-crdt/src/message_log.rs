use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

use crate::error::CrdtError;
use crate::hlc::Hlc;
use crate::traits::Mergeable;

/// Max entries per log (NASA Rule #2).
const MAX_LOG_ENTRIES: usize = 100_000;

/// Append-only CRDT for message ordering.
/// Messages keyed by HLC — total order guaranteed.
/// Supports delta-state sync via `entries_after`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MessageLog {
    entries: BTreeMap<Hlc, Vec<u8>>,
}

impl MessageLog {
    #[must_use]
    pub fn new() -> Self {
        Self {
            entries: BTreeMap::new(),
        }
    }

    /// Append a message. Returns error if log is at capacity.
    ///
    /// # Errors
    /// Returns `CrdtError::LogFull` if `MAX_LOG_ENTRIES` reached.
    pub fn append(&mut self, hlc: Hlc, data: Vec<u8>) -> Result<(), CrdtError> {
        if self.entries.len() >= MAX_LOG_ENTRIES {
            return Err(CrdtError::LogFull {
                max: MAX_LOG_ENTRIES,
            });
        }
        self.entries.insert(hlc, data);
        Ok(())
    }

    /// Delta sync: return entries strictly after `since`.
    #[must_use]
    pub fn entries_after(&self, since: &Hlc) -> Vec<(&Hlc, &Vec<u8>)> {
        use std::ops::Bound;
        self.entries
            .range((Bound::Excluded(since), Bound::Unbounded))
            .collect()
    }

    #[must_use]
    pub fn len(&self) -> usize {
        self.entries.len()
    }

    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    #[must_use]
    pub fn latest_hlc(&self) -> Option<&Hlc> {
        self.entries.keys().next_back()
    }
}

impl Default for MessageLog {
    fn default() -> Self {
        Self::new()
    }
}

impl PartialEq for MessageLog {
    fn eq(&self, other: &Self) -> bool {
        self.entries.len() == other.entries.len()
            && self
                .entries
                .iter()
                .zip(other.entries.iter())
                .all(|((k1, v1), (k2, v2))| k1 == k2 && v1 == v2)
    }
}

impl Eq for MessageLog {}

impl Mergeable for MessageLog {
    fn merge(&mut self, other: &Self) {
        for (hlc, data) in &other.entries {
            if self.entries.len() >= MAX_LOG_ENTRIES {
                break;
            }
            self.entries.entry(*hlc).or_insert_with(|| data.clone());
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
    fn append_and_retrieve() {
        let mut log = MessageLog::new();
        let h1 = hlc(100, 0, 1);
        let h2 = hlc(200, 0, 1);
        log.append(h1, b"a".to_vec()).unwrap();
        log.append(h2, b"b".to_vec()).unwrap();
        assert_eq!(log.len(), 2);
        assert_eq!(log.latest_hlc(), Some(&h2));
    }

    #[test]
    fn entries_after_returns_delta() {
        let mut log = MessageLog::new();
        let h1 = hlc(100, 0, 1);
        let h2 = hlc(200, 0, 1);
        let h3 = hlc(300, 0, 1);
        log.append(h1, b"a".to_vec()).unwrap();
        log.append(h2, b"b".to_vec()).unwrap();
        log.append(h3, b"c".to_vec()).unwrap();

        let delta = log.entries_after(&h1);
        assert_eq!(delta.len(), 2);
        assert_eq!(delta[0].0, &h2);
    }

    #[test]
    fn merge_unions() {
        let mut a = MessageLog::new();
        let mut b = MessageLog::new();
        a.append(hlc(100, 0, 1), b"a".to_vec()).unwrap();
        b.append(hlc(200, 0, 2), b"b".to_vec()).unwrap();
        a.merge(&b);
        assert_eq!(a.len(), 2);
    }

    #[test]
    fn log_full_error() {
        let mut log = MessageLog::new();
        for i in 0..MAX_LOG_ENTRIES {
            log.append(hlc(i as u64, 0, 1), b"x".to_vec()).unwrap();
        }
        let result = log.append(hlc(MAX_LOG_ENTRIES as u64, 0, 1), b"overflow".to_vec());
        assert!(result.is_err());
    }
}
