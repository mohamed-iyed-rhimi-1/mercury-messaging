use crate::traits::Mergeable;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// Grow-only counter. Used for read receipt counts.
/// Each node has its own slot. Total = sum of all slots.
/// Merge = element-wise max.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GCounter {
    counts: BTreeMap<[u8; 16], u64>,
}

impl GCounter {
    #[must_use]
    pub fn new() -> Self {
        Self {
            counts: BTreeMap::new(),
        }
    }

    pub fn increment(&mut self, node_id: [u8; 16]) {
        *self.counts.entry(node_id).or_insert(0) += 1;
    }

    #[must_use]
    pub fn value(&self) -> u64 {
        self.counts.values().sum()
    }
}

impl Default for GCounter {
    fn default() -> Self {
        Self::new()
    }
}

impl Mergeable for GCounter {
    fn merge(&mut self, other: &Self) {
        for (&node, &count) in &other.counts {
            let entry = self.counts.entry(node).or_insert(0);
            *entry = (*entry).max(count);
        }
    }
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
    fn increment_and_value() {
        let mut c = GCounter::new();
        c.increment(node(1));
        c.increment(node(1));
        c.increment(node(2));
        assert_eq!(c.value(), 3);
    }

    #[test]
    fn merge_takes_max() {
        let mut a = GCounter::new();
        a.increment(node(1));
        a.increment(node(1)); // node1=2

        let mut b = GCounter::new();
        b.increment(node(1)); // node1=1
        b.increment(node(2)); // node2=1

        a.merge(&b);
        assert_eq!(a.value(), 3); // node1=2, node2=1
    }
}
