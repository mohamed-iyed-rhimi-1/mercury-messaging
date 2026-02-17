use bytes::Bytes;

use crate::error::CoreError;
use crate::{ChannelId, MessageId, TenantId, UserId};

/// Content type discriminator. Maps to Cap'n Proto `ContentType` enum.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum ContentType {
    Text = 0,
    Image = 1,
    File = 2,
    Reaction = 3,
    Edit = 4,
    Delete = 5,
}

/// A message in the system. `encrypted_content` is opaque to the server —
/// only clients with the MLS group key can decrypt it.
#[derive(Debug, Clone)]
pub struct Message {
    pub tenant_id: TenantId,
    pub channel_id: ChannelId,
    pub id: MessageId,
    pub sender_id: UserId,
    pub encrypted_content: Bytes,
    pub content_type: ContentType,
    pub reply_to: Option<MessageId>,
    pub created_at: u64,
    pub server_received_at: Option<u64>,
}

/// Max encrypted payload size: 256 KB (NASA Rule #2).
const MAX_CONTENT_SIZE: usize = 256 * 1024;

impl Message {
    /// Validate all invariants.
    ///
    /// # Errors
    /// Returns `CoreError::InvalidMessage` if any invariant is violated.
    ///
    /// # Panics
    /// Panics if `created_at` is zero.
    pub fn validate(&self) -> Result<(), CoreError> {
        if self.encrypted_content.is_empty() && self.content_type != ContentType::Delete {
            return Err(CoreError::InvalidMessage {
                reason: "content is empty for non-delete message".into(),
            });
        }
        if self.encrypted_content.len() > MAX_CONTENT_SIZE {
            return Err(CoreError::InvalidMessage {
                reason: format!(
                    "content size {} exceeds max {}",
                    self.encrypted_content.len(),
                    MAX_CONTENT_SIZE
                ),
            });
        }
        if self.reply_to.is_some_and(|r| r == self.id) {
            return Err(CoreError::InvalidMessage {
                reason: "message cannot reply to itself".into(),
            });
        }
        assert!(self.created_at > 0, "created_at must be positive");
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_message(content: &[u8], content_type: ContentType) -> Message {
        Message {
            tenant_id: TenantId::new(),
            channel_id: ChannelId::new(),
            id: MessageId::new(),
            sender_id: UserId::new(),
            encrypted_content: Bytes::from(content.to_vec()),
            content_type,
            reply_to: None,
            created_at: 1_700_000_000_000,
            server_received_at: None,
        }
    }

    #[test]
    fn valid_text_message() {
        let msg = make_message(b"hello", ContentType::Text);
        assert!(msg.validate().is_ok());
    }

    #[test]
    fn empty_content_rejected() {
        let msg = make_message(b"", ContentType::Text);
        assert!(msg.validate().is_err());
    }

    #[test]
    fn empty_content_ok_for_delete() {
        let msg = make_message(b"", ContentType::Delete);
        assert!(msg.validate().is_ok());
    }

    #[test]
    fn oversized_content_rejected() {
        let big = vec![0u8; MAX_CONTENT_SIZE + 1];
        let msg = make_message(&big, ContentType::Text);
        assert!(msg.validate().is_err());
    }

    #[test]
    fn self_reply_rejected() {
        let mut msg = make_message(b"hello", ContentType::Text);
        msg.reply_to = Some(msg.id);
        assert!(msg.validate().is_err());
    }
}
