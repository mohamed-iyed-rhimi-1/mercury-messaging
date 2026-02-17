#[derive(Debug, thiserror::Error)]
pub enum CoreError {
    #[error("invalid message: {reason}")]
    InvalidMessage { reason: String },

    #[error("invalid channel: {reason}")]
    InvalidChannel { reason: String },

    #[error("invalid id format: {0}")]
    InvalidId(String),

    #[error("tenant context required")]
    MissingTenantContext,

    #[error("rate limit exceeded: {limit}/s")]
    RateLimitExceeded { limit: u32 },
}
