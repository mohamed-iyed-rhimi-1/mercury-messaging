#![doc = "Mercury encryption: MLS (RFC 9420) group E2EE."]

pub mod encryptor;
pub mod mls;

pub use encryptor::{Encryptor, NoopEncryptor};
