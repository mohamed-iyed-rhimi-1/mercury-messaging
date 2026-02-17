#![doc = "Mercury core domain types, validation, and shared logic."]

pub mod channel;
pub mod error;
pub mod ids;
pub mod message;
pub mod proto;
pub mod tenant;
pub mod time_bucket;

// Cap'n Proto generated modules — must be at crate root for codegen cross-references.
#[allow(clippy::all, clippy::pedantic, dead_code)]
pub mod envelope_capnp {
    include!(concat!(env!("OUT_DIR"), "/mercury/v1/envelope_capnp.rs"));
}
#[allow(clippy::all, clippy::pedantic, dead_code)]
pub mod message_capnp {
    include!(concat!(env!("OUT_DIR"), "/mercury/v1/message_capnp.rs"));
}
#[allow(clippy::all, clippy::pedantic, dead_code)]
pub mod channel_capnp {
    include!(concat!(env!("OUT_DIR"), "/mercury/v1/channel_capnp.rs"));
}
#[allow(clippy::all, clippy::pedantic, dead_code)]
pub mod sync_capnp {
    include!(concat!(env!("OUT_DIR"), "/mercury/v1/sync_capnp.rs"));
}
#[allow(clippy::all, clippy::pedantic, dead_code)]
pub mod user_capnp {
    include!(concat!(env!("OUT_DIR"), "/mercury/v1/user_capnp.rs"));
}
#[allow(clippy::all, clippy::pedantic, dead_code)]
pub mod event_capnp {
    include!(concat!(env!("OUT_DIR"), "/mercury/v1/event_capnp.rs"));
}

pub use channel::{Channel, ChannelType, MemberRole};
pub use error::CoreError;
pub use ids::{ChannelId, DeviceId, MessageId, TenantId, UserId};
pub use message::{ContentType, Message};
pub use proto::{
    envelope_decode, envelope_encode, mls_commit_decode, mls_commit_encode,
    mls_key_package_decode, mls_key_package_encode, mls_key_package_list_decode,
    mls_key_package_list_encode, mls_welcome_decode, mls_welcome_encode, read_receipt_decode,
    read_receipt_encode, typing_decode, typing_encode, DecodedEnvelope, DecodedMlsWelcome,
    DecodedReadReceipt,
};
pub use tenant::{SignupMode, TenantContext};
pub use time_bucket::TimeBucket;
