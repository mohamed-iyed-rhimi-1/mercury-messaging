//! Delta types for offline-first CRDT sync protocol.
//!
//! A `Delta` is the unit of sync — one atomic change that can be applied
//! idempotently. `DeltaBatch` is a bounded container for upstream pushes.

use crate::Hlc;
use serde::{Deserialize, Serialize};

/// Maximum deltas per batch (NASA Rule #2: fixed upper bound).
pub const MAX_DELTAS_PER_BATCH: usize = 1000;

/// Maximum deltas returned per sync response.
pub const MAX_DELTAS_PER_RESPONSE: usize = 100;

/// A single atomic change in the sync protocol.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum Delta {
    MessageAppend {
        message_id: [u8; 16],
        sender_id: [u8; 16],
        encrypted_content: Vec<u8>,
        content_type: u8,
        hlc: Hlc,
    },
    MessageEdit {
        message_id: [u8; 16],
        encrypted_content: Vec<u8>,
        hlc: Hlc,
    },
    MessageDelete {
        message_id: [u8; 16],
        hlc: Hlc,
    },
    ReactionAdd {
        message_id: [u8; 16],
        user_id: [u8; 16],
        emoji: String,
        hlc: Hlc,
    },
    ReactionRemove {
        message_id: [u8; 16],
        user_id: [u8; 16],
        emoji: String,
        hlc: Hlc,
    },
    MemberAdd {
        channel_id: [u8; 16],
        user_id: [u8; 16],
        hlc: Hlc,
    },
    MemberRemove {
        channel_id: [u8; 16],
        user_id: [u8; 16],
        hlc: Hlc,
    },
    ReadPositionUpdate {
        channel_id: [u8; 16],
        user_id: [u8; 16],
        last_read_message_id: [u8; 16],
    },
}

impl Delta {
    /// Returns the HLC of this delta, if it has one.
    #[must_use]
    pub fn hlc(&self) -> Option<&Hlc> {
        match self {
            Self::MessageAppend { hlc, .. }
            | Self::MessageEdit { hlc, .. }
            | Self::MessageDelete { hlc, .. }
            | Self::ReactionAdd { hlc, .. }
            | Self::ReactionRemove { hlc, .. }
            | Self::MemberAdd { hlc, .. }
            | Self::MemberRemove { hlc, .. } => Some(hlc),
            Self::ReadPositionUpdate { .. } => None,
        }
    }
}

/// Client → server: request deltas since a given HLC.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SyncRequest {
    pub channel_id: [u8; 16],
    pub last_hlc: Hlc,
    pub device_id: [u8; 16],
}

/// Server → client: deltas since the requested HLC.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SyncResponse {
    pub deltas: Vec<Delta>,
    pub server_hlc: Hlc,
    pub has_more: bool,
}

/// Client → server: batch of offline-queued deltas.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeltaBatch {
    pub channel_id: [u8; 16],
    pub deltas: Vec<Delta>,
    pub device_hlc: Hlc,
}

/// Result of validating a `DeltaBatch`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BatchValidation {
    Ok,
    TooLarge,
    Empty,
}

impl DeltaBatch {
    /// Validate batch bounds (NASA Rule #2).
    #[must_use]
    pub fn validate(&self) -> BatchValidation {
        if self.deltas.is_empty() {
            BatchValidation::Empty
        } else if self.deltas.len() > MAX_DELTAS_PER_BATCH {
            BatchValidation::TooLarge
        } else {
            BatchValidation::Ok
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_hlc(wall: u64) -> Hlc {
        Hlc {
            wall_clock_ms: wall,
            counter: 0,
            node_id: [0; 16],
        }
    }

    #[test]
    fn delta_serde_roundtrip() {
        let delta = Delta::MessageAppend {
            message_id: [1; 16],
            sender_id: [2; 16],
            encrypted_content: b"hello".to_vec(),
            content_type: 0,
            hlc: test_hlc(1000),
        };
        let json = serde_json::to_string(&delta).unwrap();
        let back: Delta = serde_json::from_str(&json).unwrap();
        assert_eq!(delta, back);
    }

    #[test]
    fn delta_hlc_accessor() {
        let hlc = test_hlc(42);
        let d = Delta::MessageAppend {
            message_id: [0; 16],
            sender_id: [0; 16],
            encrypted_content: vec![],
            content_type: 0,
            hlc,
        };
        assert_eq!(d.hlc(), Some(&hlc));

        let rp = Delta::ReadPositionUpdate {
            channel_id: [0; 16],
            user_id: [0; 16],
            last_read_message_id: [0; 16],
        };
        assert_eq!(rp.hlc(), None);
    }

    #[test]
    fn batch_validation() {
        let hlc = test_hlc(1);
        let empty = DeltaBatch {
            channel_id: [0; 16],
            deltas: vec![],
            device_hlc: hlc,
        };
        assert_eq!(empty.validate(), BatchValidation::Empty);

        let ok = DeltaBatch {
            channel_id: [0; 16],
            deltas: vec![Delta::MessageDelete {
                message_id: [0; 16],
                hlc,
            }],
            device_hlc: hlc,
        };
        assert_eq!(ok.validate(), BatchValidation::Ok);

        let too_large = DeltaBatch {
            channel_id: [0; 16],
            deltas: (0..1001)
                .map(|_| Delta::MessageDelete {
                    message_id: [0; 16],
                    hlc,
                })
                .collect(),
            device_hlc: hlc,
        };
        assert_eq!(too_large.validate(), BatchValidation::TooLarge);
    }

    #[test]
    fn all_delta_variants_serialize() {
        let hlc = test_hlc(100);
        let deltas = vec![
            Delta::MessageAppend {
                message_id: [1; 16],
                sender_id: [2; 16],
                encrypted_content: vec![3],
                content_type: 0,
                hlc,
            },
            Delta::MessageEdit {
                message_id: [1; 16],
                encrypted_content: vec![4],
                hlc,
            },
            Delta::MessageDelete {
                message_id: [1; 16],
                hlc,
            },
            Delta::ReactionAdd {
                message_id: [1; 16],
                user_id: [2; 16],
                emoji: "👍".into(),
                hlc,
            },
            Delta::ReactionRemove {
                message_id: [1; 16],
                user_id: [2; 16],
                emoji: "👍".into(),
                hlc,
            },
            Delta::MemberAdd {
                channel_id: [1; 16],
                user_id: [2; 16],
                hlc,
            },
            Delta::MemberRemove {
                channel_id: [1; 16],
                user_id: [2; 16],
                hlc,
            },
            Delta::ReadPositionUpdate {
                channel_id: [1; 16],
                user_id: [2; 16],
                last_read_message_id: [3; 16],
            },
        ];
        for d in &deltas {
            let json = serde_json::to_string(d).unwrap();
            let back: Delta = serde_json::from_str(&json).unwrap();
            assert_eq!(*d, back);
        }
    }

    #[test]
    fn member_add_serde_roundtrip() {
        let delta = Delta::MemberAdd {
            channel_id: [5; 16],
            user_id: [6; 16],
            hlc: test_hlc(2000),
        };
        let json = serde_json::to_string(&delta).unwrap();
        let back: Delta = serde_json::from_str(&json).unwrap();
        assert_eq!(delta, back);
        assert!(json.contains("\"MemberAdd\""));
    }

    #[test]
    fn member_remove_serde_roundtrip() {
        let delta = Delta::MemberRemove {
            channel_id: [7; 16],
            user_id: [8; 16],
            hlc: test_hlc(3000),
        };
        let json = serde_json::to_string(&delta).unwrap();
        let back: Delta = serde_json::from_str(&json).unwrap();
        assert_eq!(delta, back);
        assert!(json.contains("\"MemberRemove\""));
    }

    #[test]
    fn member_add_has_hlc() {
        let hlc = test_hlc(99);
        let d = Delta::MemberAdd {
            channel_id: [0; 16],
            user_id: [0; 16],
            hlc,
        };
        assert_eq!(d.hlc(), Some(&hlc));
    }

    #[test]
    fn sync_request_response_serde() {
        let req = SyncRequest {
            channel_id: [1; 16],
            last_hlc: test_hlc(500),
            device_id: [2; 16],
        };
        let json = serde_json::to_string(&req).unwrap();
        let back: SyncRequest = serde_json::from_str(&json).unwrap();
        assert_eq!(back.channel_id, req.channel_id);

        let resp = SyncResponse {
            deltas: vec![],
            server_hlc: test_hlc(600),
            has_more: false,
        };
        let json = serde_json::to_string(&resp).unwrap();
        let back: SyncResponse = serde_json::from_str(&json).unwrap();
        assert!(!back.has_more);
        assert!(back.deltas.is_empty());
    }
}
