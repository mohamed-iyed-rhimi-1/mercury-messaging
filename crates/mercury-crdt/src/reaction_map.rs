use crate::orset::ORSet;
use crate::traits::Mergeable;
use mercury_core::UserId;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// Specialized CRDT for message reactions.
/// Internally an `ORSet<(UserId, String)>`. Set semantics = natural dedup
/// (one reaction per user per emoji).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReactionMap {
    reactions: ORSet<(UserId, String)>,
}

impl ReactionMap {
    #[must_use]
    pub fn new() -> Self {
        Self {
            reactions: ORSet::new(),
        }
    }

    pub fn add_reaction(&mut self, user: UserId, emoji: String, node_id: [u8; 16]) {
        self.reactions.add((user, emoji), node_id);
    }

    pub fn remove_reaction(&mut self, user: &UserId, emoji: &str) {
        self.reactions.remove(&(*user, emoji.to_owned()));
    }

    #[must_use]
    pub fn counts(&self) -> BTreeMap<String, usize> {
        let mut map = BTreeMap::new();
        for (_, emoji) in self.reactions.elements() {
            *map.entry(emoji.clone()).or_insert(0) += 1;
        }
        map
    }

    #[must_use]
    pub fn user_reactions(&self, user: &UserId) -> Vec<String> {
        self.reactions
            .elements()
            .filter(|(u, _)| u == user)
            .map(|(_, e)| e.clone())
            .collect()
    }

    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.reactions.is_empty()
    }
}

impl Default for ReactionMap {
    fn default() -> Self {
        Self::new()
    }
}

impl Mergeable for ReactionMap {
    fn merge(&mut self, other: &Self) {
        self.reactions.merge(&other.reactions);
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
    fn add_and_count() {
        let mut rm = ReactionMap::new();
        let u1 = UserId::new();
        let u2 = UserId::new();
        rm.add_reaction(u1, "👍".into(), node(1));
        rm.add_reaction(u2, "👍".into(), node(2));
        assert_eq!(rm.counts()["👍"], 2);
    }

    #[test]
    fn same_user_same_emoji_deduped() {
        let mut rm = ReactionMap::new();
        let u = UserId::new();
        rm.add_reaction(u, "👍".into(), node(1));
        rm.add_reaction(u, "👍".into(), node(1));
        // ORSet stores both dots for same key, but key is (user, emoji) which is same
        // so it's one entry with two dots — counts as 1
        assert_eq!(rm.counts()["👍"], 1);
    }

    #[test]
    fn remove_reaction() {
        let mut rm = ReactionMap::new();
        let u = UserId::new();
        rm.add_reaction(u, "👍".into(), node(1));
        rm.remove_reaction(&u, "👍");
        assert!(rm.is_empty());
    }

    #[test]
    fn user_reactions_list() {
        let mut rm = ReactionMap::new();
        let u = UserId::new();
        rm.add_reaction(u, "👍".into(), node(1));
        rm.add_reaction(u, "❤️".into(), node(1));
        let mut reacts = rm.user_reactions(&u);
        reacts.sort();
        assert_eq!(reacts.len(), 2);
    }

    #[test]
    fn merge_unions() {
        let mut a = ReactionMap::new();
        let mut b = ReactionMap::new();
        let u1 = UserId::new();
        let u2 = UserId::new();
        a.add_reaction(u1, "👍".into(), node(1));
        b.add_reaction(u2, "❤️".into(), node(2));
        a.merge(&b);
        assert_eq!(a.counts().len(), 2);
    }
}
