use crate::traits::Mergeable;
use serde::{Deserialize, Serialize};
use std::collections::{BTreeSet, HashMap};
use std::hash::Hash;

/// A unique tag for each add operation.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
pub struct Dot {
    pub node_id: [u8; 16],
    pub seq: u64,
}

/// Observed-Remove Set. Supports concurrent add + remove without conflict.
/// Add wins over concurrent remove (availability bias).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ORSet<T: Eq + Hash + Clone> {
    entries: HashMap<T, BTreeSet<Dot>>,
    next_seq: HashMap<[u8; 16], u64>,
}

impl<T: Eq + Hash + Clone> ORSet<T> {
    #[must_use]
    pub fn new() -> Self {
        Self {
            entries: HashMap::new(),
            next_seq: HashMap::new(),
        }
    }

    pub fn add(&mut self, value: T, node_id: [u8; 16]) {
        let seq = self.next_seq.entry(node_id).or_insert(0);
        *seq += 1;
        let dot = Dot { node_id, seq: *seq };
        self.entries.entry(value).or_default().insert(dot);
    }

    pub fn remove(&mut self, value: &T) {
        self.entries.remove(value);
    }

    #[must_use]
    pub fn contains(&self, value: &T) -> bool {
        self.entries.get(value).is_some_and(|dots| !dots.is_empty())
    }

    pub fn elements(&self) -> impl Iterator<Item = &T> {
        self.entries
            .iter()
            .filter(|(_, dots)| !dots.is_empty())
            .map(|(k, _)| k)
    }

    #[must_use]
    pub fn len(&self) -> usize {
        self.entries
            .values()
            .filter(|dots| !dots.is_empty())
            .count()
    }

    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

impl<T: Eq + Hash + Clone> Default for ORSet<T> {
    fn default() -> Self {
        Self::new()
    }
}

impl<T: Eq + Hash + Clone> Mergeable for ORSet<T> {
    fn merge(&mut self, other: &Self) {
        for (value, other_dots) in &other.entries {
            let dots = self.entries.entry(value.clone()).or_default();
            for dot in other_dots {
                dots.insert(*dot);
            }
        }
        for (&node, &seq) in &other.next_seq {
            let entry = self.next_seq.entry(node).or_insert(0);
            *entry = (*entry).max(seq);
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
    fn add_and_contains() {
        let mut set = ORSet::new();
        set.add("a", node(1));
        assert!(set.contains(&"a"));
        assert_eq!(set.len(), 1);
    }

    #[test]
    fn add_then_remove() {
        let mut set = ORSet::new();
        set.add("a", node(1));
        set.remove(&"a");
        assert!(!set.contains(&"a"));
        assert!(set.is_empty());
    }

    #[test]
    fn concurrent_add_both_present() {
        let mut a = ORSet::new();
        a.add("x", node(1));

        let mut b = ORSet::new();
        b.add("y", node(2));

        a.merge(&b);
        assert!(a.contains(&"x"));
        assert!(a.contains(&"y"));
    }

    #[test]
    fn concurrent_add_and_remove_add_wins() {
        // Node 1 adds "x"
        let mut a = ORSet::new();
        a.add("x", node(1));

        // Node 2 independently adds "x" then we merge
        let mut b = ORSet::new();
        b.add("x", node(2));

        // Node 1 removes "x" (only removes its own dot)
        a.remove(&"x");

        // Merge: node 2's dot survives → "x" is present
        a.merge(&b);
        assert!(a.contains(&"x"));
    }
}
