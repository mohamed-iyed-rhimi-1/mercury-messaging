use mercury_crdt::*;
use proptest::prelude::*;

// --- Helpers ---

fn arb_node_id() -> impl Strategy<Value = [u8; 16]> {
    prop::array::uniform16(any::<u8>())
}

fn arb_hlc() -> impl Strategy<Value = Hlc> {
    (1u64..1_000_000, 0u32..100, arb_node_id()).prop_map(|(wall, counter, node_id)| Hlc {
        wall_clock_ms: wall,
        counter,
        node_id,
    })
}

fn arb_gcounter() -> impl Strategy<Value = GCounter> {
    prop::collection::vec((arb_node_id(), 1u64..100), 0..5).prop_map(|ops| {
        let mut c = GCounter::new();
        for (node, count) in ops {
            for _ in 0..count {
                c.increment(node);
            }
        }
        c
    })
}

fn arb_lww_register() -> impl Strategy<Value = LwwRegister<u64>> {
    (any::<u64>(), arb_hlc()).prop_map(|(val, hlc)| LwwRegister::new(val, hlc))
}

fn arb_orset() -> impl Strategy<Value = ORSet<u32>> {
    prop::collection::vec((0u32..50, arb_node_id()), 0..10).prop_map(|ops| {
        let mut s = ORSet::new();
        for (val, node) in ops {
            s.add(val, node);
        }
        s
    })
}

fn arb_message_log() -> impl Strategy<Value = MessageLog> {
    prop::collection::vec(
        (arb_hlc(), prop::collection::vec(any::<u8>(), 0..16)),
        0..10,
    )
    .prop_map(|ops| {
        let mut log = MessageLog::new();
        for (hlc, data) in ops {
            let _ = log.append(hlc, data);
        }
        log
    })
}

// --- Macro for CRDT laws ---

macro_rules! crdt_laws {
    ($name:ident, $arb:expr) => {
        mod $name {
            use super::*;

            proptest! {
                #[test]
                fn commutative(a in $arb, b in $arb) {
                    let mut ab = a.clone();
                    ab.merge(&b);
                    let mut ba = b.clone();
                    ba.merge(&a);
                    prop_assert_eq!(ab, ba);
                }

                #[test]
                fn associative(a in $arb, b in $arb, c in $arb) {
                    let mut ab_c = a.clone();
                    ab_c.merge(&b);
                    ab_c.merge(&c);

                    let mut a_bc = a.clone();
                    let mut bc = b.clone();
                    bc.merge(&c);
                    a_bc.merge(&bc);

                    prop_assert_eq!(ab_c, a_bc);
                }

                #[test]
                fn idempotent(a in $arb) {
                    let mut merged = a.clone();
                    merged.merge(&a);
                    prop_assert_eq!(merged, a);
                }
            }
        }
    };
}

crdt_laws!(gcounter_laws, arb_gcounter());
crdt_laws!(lww_register_laws, arb_lww_register());
crdt_laws!(orset_laws, arb_orset());
crdt_laws!(message_log_laws, arb_message_log());

// ReactionMap uses ORSet internally, but test it separately for completeness
mod reaction_map_laws {
    use super::*;
    use mercury_core::UserId;

    fn arb_reaction_map() -> impl Strategy<Value = ReactionMap> {
        prop::collection::vec((any::<u8>(), 0u8..3, arb_node_id()), 0..5).prop_map(|ops| {
            let mut rm = ReactionMap::new();
            let emojis = ["👍", "❤️", "😂"];
            for (_, emoji_idx, node) in ops {
                rm.add_reaction(UserId::new(), emojis[emoji_idx as usize].into(), node);
            }
            rm
        })
    }

    proptest! {
        #[test]
        fn commutative(a in arb_reaction_map(), b in arb_reaction_map()) {
            let mut ab = a.clone();
            ab.merge(&b);
            let mut ba = b.clone();
            ba.merge(&a);
            prop_assert_eq!(ab, ba);
        }

        #[test]
        fn idempotent(a in arb_reaction_map()) {
            let mut merged = a.clone();
            merged.merge(&a);
            prop_assert_eq!(merged, a);
        }
    }
}
