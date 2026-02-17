#[derive(Debug, thiserror::Error)]
pub enum CrdtError {
    #[error("message log full: max {max} entries")]
    LogFull { max: usize },
}
