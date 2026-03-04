//! Trait-based encryption abstraction.
//!
//! `Encryptor` provides a pluggable interface for group encryption.
//! `NoopEncryptor` is a pass-through implementation for development/testing.

use anyhow::Result;

/// Pluggable group encryption interface.
pub trait Encryptor {
    /// Encrypt plaintext for a group. Returns ciphertext bytes.
    ///
    /// # Errors
    /// Returns error if encryption fails.
    fn encrypt(&mut self, group_id: &[u8], plaintext: &[u8]) -> Result<Vec<u8>>;

    /// Decrypt ciphertext from a group. Returns plaintext bytes.
    ///
    /// # Errors
    /// Returns error if decryption fails.
    fn decrypt(&mut self, group_id: &[u8], ciphertext: &[u8]) -> Result<Vec<u8>>;
}

impl Encryptor for crate::mls::MlsGroupManager {
    fn encrypt(&mut self, group_id: &[u8], plaintext: &[u8]) -> Result<Vec<u8>> {
        self.encrypt(group_id, plaintext)
    }

    fn decrypt(&mut self, group_id: &[u8], ciphertext: &[u8]) -> Result<Vec<u8>> {
        self.decrypt(group_id, ciphertext)
    }
}

/// Identity (no-op) encryptor — returns input unchanged.
/// Use only for development and testing.
pub struct NoopEncryptor;

impl Encryptor for NoopEncryptor {
    fn encrypt(&mut self, _group_id: &[u8], plaintext: &[u8]) -> Result<Vec<u8>> {
        Ok(plaintext.to_vec())
    }

    fn decrypt(&mut self, _group_id: &[u8], ciphertext: &[u8]) -> Result<Vec<u8>> {
        Ok(ciphertext.to_vec())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn noop_roundtrip() {
        let mut enc = NoopEncryptor;
        let plaintext = b"hello world";
        let ct = enc.encrypt(b"group1", plaintext).unwrap();
        assert_eq!(ct, plaintext);
        let pt = enc.decrypt(b"group1", &ct).unwrap();
        assert_eq!(pt, plaintext);
    }

    #[test]
    fn noop_as_trait_object() {
        let mut enc: Box<dyn Encryptor> = Box::new(NoopEncryptor);
        let ct = enc.encrypt(b"g", b"data").unwrap();
        let pt = enc.decrypt(b"g", &ct).unwrap();
        assert_eq!(pt, b"data");
    }
}
