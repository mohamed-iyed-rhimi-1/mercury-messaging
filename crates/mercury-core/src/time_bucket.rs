use crate::MessageId;
use serde::{Deserialize, Serialize};

/// Time bucket for `ScyllaDB` partition keys.
/// `bucket_id = unix_epoch_days / 10`
/// New partition every 10 days per channel — prevents unbounded growth (NASA Rule #2).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct TimeBucket(u32);

const MS_PER_DAY: u64 = 86_400_000;
const DAYS_PER_BUCKET: u64 = 10;

impl TimeBucket {
    /// Compute bucket from Unix timestamp in milliseconds.
    ///
    /// # Panics
    /// Panics if timestamp is so far in the future it overflows `u32`.
    #[must_use]
    pub fn from_timestamp_ms(ts_ms: u64) -> Self {
        let epoch_days = ts_ms / MS_PER_DAY;
        let bucket = epoch_days / DAYS_PER_BUCKET;
        Self(u32::try_from(bucket).expect("timestamp too far in future"))
    }

    /// Compute bucket from a [`MessageId`] (extracts embedded timestamp).
    #[must_use]
    pub fn from_message_id(id: &MessageId) -> Self {
        Self::from_timestamp_ms(id.timestamp_ms())
    }

    /// Raw bucket value for CQL queries.
    #[must_use]
    #[allow(clippy::cast_possible_wrap)]
    pub fn as_i32(self) -> i32 {
        self.0 as i32
    }

    /// Raw bucket value.
    #[must_use]
    pub fn as_u32(self) -> u32 {
        self.0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn known_timestamp() {
        // 2024-01-01 00:00:00 UTC = 1_704_067_200_000 ms
        let ts = 1_704_067_200_000_u64;
        let bucket = TimeBucket::from_timestamp_ms(ts);
        let expected_days = ts / MS_PER_DAY; // 19723
        let expected_bucket = expected_days / DAYS_PER_BUCKET; // 1972
        assert_eq!(u64::from(bucket.as_u32()), expected_bucket);
    }

    #[test]
    fn same_bucket_within_10_days() {
        // Use a timestamp aligned to a bucket boundary
        // bucket 1972 starts at day 19720, which is 19720 * MS_PER_DAY
        let bucket_start = 1972 * DAYS_PER_BUCKET * MS_PER_DAY;
        let day9 = bucket_start + 9 * MS_PER_DAY;
        assert_eq!(
            TimeBucket::from_timestamp_ms(bucket_start),
            TimeBucket::from_timestamp_ms(day9)
        );
    }

    #[test]
    fn different_bucket_after_10_days() {
        let bucket_start = 1972 * DAYS_PER_BUCKET * MS_PER_DAY;
        let day10 = bucket_start + 10 * MS_PER_DAY;
        assert_ne!(
            TimeBucket::from_timestamp_ms(bucket_start),
            TimeBucket::from_timestamp_ms(day10)
        );
    }

    #[test]
    fn from_message_id() {
        let id = MessageId::new();
        let bucket_from_id = TimeBucket::from_message_id(&id);
        let bucket_from_ts = TimeBucket::from_timestamp_ms(id.timestamp_ms());
        assert_eq!(bucket_from_id, bucket_from_ts);
    }
}
