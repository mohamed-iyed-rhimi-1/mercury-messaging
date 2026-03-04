use crate::error::CoreError;
use crate::{ChannelId, TenantId, UserId};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum ChannelType {
    Dm = 0,
    Group = 1,
    Broadcast = 2,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum MemberRole {
    Member = 0,
    Admin = 1,
    Owner = 2,
}

#[derive(Debug, Clone)]
pub struct Channel {
    pub tenant_id: TenantId,
    pub id: ChannelId,
    pub channel_type: ChannelType,
    pub name: Option<String>,
    pub member_ids: Vec<UserId>,
    pub created_by: UserId,
    pub created_at: u64,
}

/// Max channel name length (NASA Rule #2).
const MAX_NAME_LEN: usize = 128;

/// Max channel members (NASA Rule #2).
const MAX_CHANNEL_MEMBERS: usize = 1000;

impl Channel {
    /// Validate all invariants.
    ///
    /// # Errors
    /// Returns `CoreError::InvalidChannel` if any invariant is violated.
    ///
    /// # Panics
    /// Panics if `created_at` is zero.
    pub fn validate(&self) -> Result<(), CoreError> {
        match self.channel_type {
            ChannelType::Dm => {
                if self.name.is_some() {
                    return Err(CoreError::InvalidChannel {
                        reason: "DM channels must not have a name".into(),
                    });
                }
                if !self.member_ids.is_empty() && self.member_ids.len() != 2 {
                    return Err(CoreError::InvalidChannel {
                        reason: "DM channels must have exactly 2 members".into(),
                    });
                }
            }
            ChannelType::Group | ChannelType::Broadcast => {
                let Some(name) = &self.name else {
                    return Err(CoreError::InvalidChannel {
                        reason: "group/broadcast channels require a name".into(),
                    });
                };
                if name.is_empty() || name.len() > MAX_NAME_LEN {
                    return Err(CoreError::InvalidChannel {
                        reason: format!("name length must be 1..={MAX_NAME_LEN}"),
                    });
                }
                if self.member_ids.len() > MAX_CHANNEL_MEMBERS {
                    return Err(CoreError::InvalidChannel {
                        reason: format!(
                            "member count {} exceeds max {MAX_CHANNEL_MEMBERS}",
                            self.member_ids.len()
                        ),
                    });
                }
            }
        }
        assert!(self.created_at > 0, "created_at must be positive");
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_channel(channel_type: ChannelType, name: Option<&str>) -> Channel {
        Channel {
            tenant_id: TenantId::new(),
            id: ChannelId::new(),
            channel_type,
            name: name.map(String::from),
            member_ids: vec![],
            created_by: UserId::new(),
            created_at: 1_700_000_000_000,
        }
    }

    #[test]
    fn valid_dm() {
        assert!(make_channel(ChannelType::Dm, None).validate().is_ok());
    }

    #[test]
    fn dm_with_name_rejected() {
        assert!(
            make_channel(ChannelType::Dm, Some("oops"))
                .validate()
                .is_err()
        );
    }

    #[test]
    fn valid_group() {
        assert!(
            make_channel(ChannelType::Group, Some("general"))
                .validate()
                .is_ok()
        );
    }

    #[test]
    fn group_without_name_rejected() {
        assert!(make_channel(ChannelType::Group, None).validate().is_err());
    }

    #[test]
    fn name_too_long_rejected() {
        let long = "a".repeat(MAX_NAME_LEN + 1);
        assert!(
            make_channel(ChannelType::Group, Some(&long))
                .validate()
                .is_err()
        );
    }

    #[test]
    fn empty_name_rejected() {
        assert!(
            make_channel(ChannelType::Group, Some(""))
                .validate()
                .is_err()
        );
    }

    #[test]
    fn dm_with_two_members_valid() {
        let mut ch = make_channel(ChannelType::Dm, None);
        ch.member_ids = vec![UserId::new(), UserId::new()];
        assert!(ch.validate().is_ok());
    }

    #[test]
    fn dm_with_one_member_rejected() {
        let mut ch = make_channel(ChannelType::Dm, None);
        ch.member_ids = vec![UserId::new()];
        assert!(ch.validate().is_err());
    }

    #[test]
    fn dm_with_three_members_rejected() {
        let mut ch = make_channel(ChannelType::Dm, None);
        ch.member_ids = vec![UserId::new(), UserId::new(), UserId::new()];
        assert!(ch.validate().is_err());
    }

    #[test]
    fn group_exceeding_max_members_rejected() {
        let mut ch = make_channel(ChannelType::Group, Some("big"));
        ch.member_ids = (0..1001).map(|_| UserId::new()).collect();
        assert!(ch.validate().is_err());
    }

    #[test]
    fn group_at_max_members_valid() {
        let mut ch = make_channel(ChannelType::Group, Some("big"));
        ch.member_ids = (0..1000).map(|_| UserId::new()).collect();
        assert!(ch.validate().is_ok());
    }
}
