use serde::{Deserialize, Serialize};
use std::fmt;
use std::str::FromStr;
use uuid::Uuid;

/// Tenant identifier. Present on EVERY domain object.
/// Multi-tenancy enforced at the type level.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct TenantId(Uuid);

impl TenantId {
    #[must_use]
    pub fn new() -> Self {
        Self(Uuid::new_v4())
    }

    /// # Panics
    /// Panics if `bytes` is not exactly 16 bytes.
    #[must_use]
    pub fn from_bytes(bytes: [u8; 16]) -> Self {
        Self(Uuid::from_bytes(bytes))
    }

    #[must_use]
    pub fn as_bytes(&self) -> &[u8; 16] {
        self.0.as_bytes()
    }
}

impl Default for TenantId {
    fn default() -> Self {
        Self::new()
    }
}

impl fmt::Display for TenantId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.0.fmt(f)
    }
}

impl FromStr for TenantId {
    type Err = uuid::Error;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Uuid::from_str(s).map(Self)
    }
}

/// ULID-based message identifier. Sortable, embeds creation timestamp.
/// See ADR-002: chosen over `UUIDv7` for Crockford Base32 encoding.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
pub struct MessageId(ulid::Ulid);

impl MessageId {
    #[must_use]
    pub fn new() -> Self {
        Self(ulid::Ulid::new())
    }

    #[must_use]
    pub fn from_bytes(bytes: [u8; 16]) -> Self {
        Self(ulid::Ulid::from_bytes(bytes))
    }

    #[must_use]
    pub fn as_bytes(&self) -> [u8; 16] {
        self.0.to_bytes()
    }

    /// Extract embedded creation timestamp as Unix milliseconds.
    #[must_use]
    pub fn timestamp_ms(&self) -> u64 {
        self.0.timestamp_ms()
    }
}

impl Default for MessageId {
    fn default() -> Self {
        Self::new()
    }
}

impl fmt::Display for MessageId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.0.fmt(f)
    }
}

impl FromStr for MessageId {
    type Err = ulid::DecodeError;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        ulid::Ulid::from_str(s).map(Self)
    }
}

// Macro to reduce boilerplate for UUID-based newtypes
macro_rules! uuid_id {
    ($(#[$meta:meta])* $name:ident) => {
        $(#[$meta])*
        #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
        pub struct $name(Uuid);

        impl $name {
            #[must_use]
            pub fn new() -> Self {
                Self(Uuid::new_v4())
            }

            #[must_use]
            pub fn from_bytes(bytes: [u8; 16]) -> Self {
                Self(Uuid::from_bytes(bytes))
            }

            #[must_use]
            pub fn as_bytes(&self) -> &[u8; 16] {
                self.0.as_bytes()
            }
        }

        impl Default for $name {
            fn default() -> Self {
                Self::new()
            }
        }

        impl fmt::Display for $name {
            fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                self.0.fmt(f)
            }
        }

        impl FromStr for $name {
            type Err = uuid::Error;
            fn from_str(s: &str) -> Result<Self, Self::Err> {
                Uuid::from_str(s).map(Self)
            }
        }
    };
}

uuid_id!(/// Channel identifier.
ChannelId);
uuid_id!(/// User identifier.
UserId);
uuid_id!(/// Device identifier.
DeviceId);

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tenant_id_roundtrip() {
        let id = TenantId::new();
        let s = id.to_string();
        let parsed: TenantId = s.parse().unwrap();
        assert_eq!(id, parsed);
    }

    #[test]
    fn tenant_id_bytes_roundtrip() {
        let id = TenantId::new();
        let bytes = *id.as_bytes();
        let restored = TenantId::from_bytes(bytes);
        assert_eq!(id, restored);
    }

    #[test]
    fn message_id_roundtrip() {
        let id = MessageId::new();
        let s = id.to_string();
        let parsed: MessageId = s.parse().unwrap();
        assert_eq!(id, parsed);
    }

    #[test]
    fn message_id_bytes_roundtrip() {
        let id = MessageId::new();
        let bytes = id.as_bytes();
        let restored = MessageId::from_bytes(bytes);
        assert_eq!(id, restored);
    }

    #[test]
    fn message_id_ordering() {
        let a = MessageId::new();
        std::thread::sleep(std::time::Duration::from_millis(2));
        let b = MessageId::new();
        assert!(a < b, "later MessageId should sort higher");
    }

    #[test]
    fn message_id_has_timestamp() {
        let before = u64::try_from(
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_millis(),
        )
        .unwrap();
        let id = MessageId::new();
        let after = u64::try_from(
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_millis(),
        )
        .unwrap();
        assert!(id.timestamp_ms() >= before);
        assert!(id.timestamp_ms() <= after);
    }

    #[test]
    fn channel_id_roundtrip() {
        let id = ChannelId::new();
        let s = id.to_string();
        let parsed: ChannelId = s.parse().unwrap();
        assert_eq!(id, parsed);
    }

    #[test]
    fn user_id_roundtrip() {
        let id = UserId::new();
        let bytes = *id.as_bytes();
        let restored = UserId::from_bytes(bytes);
        assert_eq!(id, restored);
    }

    #[test]
    fn device_id_roundtrip() {
        let id = DeviceId::new();
        let s = id.to_string();
        let parsed: DeviceId = s.parse().unwrap();
        assert_eq!(id, parsed);
    }
}
