#![doc = "Mercury CRDT implementations: HLC, `GCounter`, `LWWRegister`, `ORSet`, `ReactionMap`, `MessageLog`."]

pub mod delta;
pub mod error;
pub mod gcounter;
pub mod hlc;
pub mod lww_register;
pub mod message_log;
pub mod orset;
pub mod reaction_map;
pub mod traits;

pub use error::CrdtError;
pub use gcounter::GCounter;
pub use hlc::Hlc;
pub use lww_register::LwwRegister;
pub use message_log::MessageLog;
pub use orset::ORSet;
pub use reaction_map::ReactionMap;
pub use traits::Mergeable;
