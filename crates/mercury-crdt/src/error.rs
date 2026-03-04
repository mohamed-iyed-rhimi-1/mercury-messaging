#[derive(Debug, thiserror::Error)]
pub enum CrdtError {
    #[error("message log full: max {max} entries")]
    LogFull { max: usize },

    #[error("invalid delta: {reason}")]
    InvalidDelta { reason: String },

    #[error("merge conflict: {reason}")]
    MergeConflict { reason: String },
}
