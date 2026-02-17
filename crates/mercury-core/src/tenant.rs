use crate::TenantId;

/// Tenant-scoped configuration threaded through all service calls.
#[derive(Debug, Clone)]
pub struct TenantContext {
    pub tenant_id: TenantId,
    pub max_users: u32,
    pub max_channels: u32,
    pub max_file_size_mb: u32,
    pub rate_limit_per_user: u32,
    pub signup_mode: SignupMode,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SignupMode {
    Open,
    InviteOnly,
    Waitlist,
}

impl TenantContext {
    /// Create a context with default limits.
    #[must_use]
    pub fn new(tenant_id: TenantId) -> Self {
        Self {
            tenant_id,
            max_users: 1_000,
            max_channels: 100,
            max_file_size_mb: 25,
            rate_limit_per_user: 100,
            signup_mode: SignupMode::Open,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_limits() {
        let ctx = TenantContext::new(TenantId::new());
        assert_eq!(ctx.max_users, 1_000);
        assert_eq!(ctx.rate_limit_per_user, 100);
        assert_eq!(ctx.signup_mode, SignupMode::Open);
    }
}
