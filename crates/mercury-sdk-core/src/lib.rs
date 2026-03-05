#![doc = "Mercury SDK core — compiled to WASM for the Web SDK."]
#![allow(
    clippy::missing_errors_doc,
    clippy::missing_panics_doc,
    clippy::must_use_candidate
)]

use mercury_core::{MessageId, TimeBucket};
use wasm_bindgen::prelude::*;

// ── ID generation ──

/// Generate a new ULID message ID (Crockford Base32 string).
#[wasm_bindgen(js_name = "generateMessageId")]
pub fn generate_message_id() -> String {
    MessageId::new().to_string()
}

/// Compute the time bucket for a given timestamp (`epoch_days` / 10).
#[wasm_bindgen(js_name = "computeTimeBucket")]
pub fn compute_time_bucket(timestamp_ms: u64) -> u32 {
    TimeBucket::from_timestamp_ms(timestamp_ms).as_u32()
}

// ── Validation ──

/// Validate message content. Returns empty string on success, error message on failure.
#[wasm_bindgen(js_name = "validateMessage")]
pub fn validate_message(content: &[u8], content_type: u8) -> String {
    if content.is_empty() && content_type != 5 {
        return "content is empty for non-delete message".into();
    }
    if content.len() > 256 * 1024 {
        return format!("content size {} exceeds max 262144", content.len());
    }
    String::new()
}

// ── MLS Encryption ──

use mercury_crypto::mls::MlsGroupManager;

/// MLS group manager — holds per-device identity and group state.
/// Exposed as a JS class via wasm-bindgen.
#[wasm_bindgen]
pub struct MlsManager {
    inner: MlsGroupManager,
}

#[wasm_bindgen]
impl MlsManager {
    /// Create a new MLS identity for this device.
    #[wasm_bindgen(constructor)]
    pub fn new(identity: &[u8]) -> Result<MlsManager, JsError> {
        let inner =
            MlsGroupManager::new(identity).map_err(|e| JsError::new(&format!("MLS init: {e}")))?;
        Ok(Self { inner })
    }

    /// Generate a fresh `KeyPackage` for upload to the server.
    #[wasm_bindgen(js_name = "generateKeyPackage")]
    pub fn generate_key_package(&self) -> Result<Vec<u8>, JsError> {
        self.inner
            .generate_key_package()
            .map_err(|e| JsError::new(&format!("KeyPackage: {e}")))
    }

    /// Create a new MLS group (maps to a Mercury channel).
    #[wasm_bindgen(js_name = "createGroup")]
    pub fn create_group(&mut self, group_id: &[u8]) -> Result<(), JsError> {
        self.inner
            .create_group(group_id)
            .map_err(|e| JsError::new(&format!("createGroup: {e}")))
    }

    /// Add a member to a group. Returns `[commit, welcome]` as concatenated bytes
    /// with a 4-byte big-endian length prefix for the commit.
    #[wasm_bindgen(js_name = "addMember")]
    pub fn add_member(
        &mut self,
        group_id: &[u8],
        key_package: &[u8],
    ) -> Result<Vec<u8>, JsError> {
        let (commit, welcome) = self
            .inner
            .add_member(group_id, key_package)
            .map_err(|e| JsError::new(&format!("addMember: {e}")))?;
        // Pack: [commit_len(4 bytes BE), commit, welcome]
        let mut out = Vec::with_capacity(4 + commit.len() + welcome.len());
        out.extend_from_slice(&u32::try_from(commit.len()).expect("commit fits u32").to_be_bytes());
        out.extend_from_slice(&commit);
        out.extend_from_slice(&welcome);
        Ok(out)
    }

    /// Encrypt plaintext for a group. Returns MLS ciphertext.
    #[wasm_bindgen]
    pub fn encrypt(&mut self, group_id: &[u8], plaintext: &[u8]) -> Result<Vec<u8>, JsError> {
        self.inner
            .encrypt(group_id, plaintext)
            .map_err(|e| JsError::new(&format!("encrypt: {e}")))
    }

    /// Decrypt MLS ciphertext. Returns plaintext.
    #[wasm_bindgen]
    pub fn decrypt(&mut self, group_id: &[u8], ciphertext: &[u8]) -> Result<Vec<u8>, JsError> {
        self.inner
            .decrypt(group_id, ciphertext)
            .map_err(|e| JsError::new(&format!("decrypt: {e}")))
    }

    /// Join a group from a Welcome message. Returns the `group_id`.
    #[wasm_bindgen(js_name = "processWelcome")]
    pub fn process_welcome(&mut self, welcome: &[u8]) -> Result<Vec<u8>, JsError> {
        self.inner
            .process_welcome(welcome)
            .map_err(|e| JsError::new(&format!("processWelcome: {e}")))
    }

    /// Process a Commit message (member add/remove/update).
    #[wasm_bindgen(js_name = "processCommit")]
    pub fn process_commit(&mut self, group_id: &[u8], commit: &[u8]) -> Result<(), JsError> {
        self.inner
            .process_commit(group_id, commit)
            .map_err(|e| JsError::new(&format!("processCommit: {e}")))
    }

    /// Remove a member from a group by leaf index. Returns the commit bytes.
    #[wasm_bindgen(js_name = "removeMember")]
    pub fn remove_member(
        &mut self,
        group_id: &[u8],
        member_index: u32,
    ) -> Result<Vec<u8>, JsError> {
        self.inner
            .remove_member(group_id, member_index)
            .map_err(|e| JsError::new(&format!("removeMember: {e}")))
    }

    /// Get the number of members in a group.
    #[wasm_bindgen(js_name = "memberCount")]
    pub fn member_count(&self, group_id: &[u8]) -> Result<u32, JsError> {
        self.inner
            .member_count(group_id)
            .map(|n| u32::try_from(n).expect("member count fits u32"))
            .ok_or_else(|| JsError::new("group not found"))
    }
}

/// Generate an MLS `KeyPackage` for this device identity (standalone, no state).
#[wasm_bindgen(js_name = "generateKeyPackage")]
pub fn generate_key_package(identity: &[u8]) -> Result<Vec<u8>, JsError> {
    let mgr =
        MlsGroupManager::new(identity).map_err(|e| JsError::new(&format!("MLS init: {e}")))?;
    mgr.generate_key_package()
        .map_err(|e| JsError::new(&format!("KeyPackage: {e}")))
}

// ── Delta / CRDT ──

/// Validate and parse a delta JSON string. Returns empty string if valid.
#[wasm_bindgen(js_name = "validateDelta")]
pub fn validate_delta(delta_json: &str) -> String {
    match serde_json::from_str::<mercury_crdt::delta::Delta>(delta_json) {
        Ok(_) => String::new(),
        Err(e) => e.to_string(),
    }
}

/// Validate a batch of deltas (checks count bounds). Returns empty string if valid.
#[wasm_bindgen(js_name = "validateDeltaBatch")]
pub fn validate_delta_batch(count: usize) -> String {
    if count == 0 {
        return "batch is empty".into();
    }
    if count > mercury_crdt::delta::MAX_DELTAS_PER_BATCH {
        return format!("batch too large: {count} deltas");
    }
    String::new()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn message_id_is_26_chars() {
        let id = generate_message_id();
        assert_eq!(id.len(), 26);
    }

    #[test]
    fn time_bucket_known_value() {
        let bucket = compute_time_bucket(1_704_067_200_000);
        assert_eq!(bucket, 1972);
    }

    #[test]
    fn validate_ok() {
        assert!(validate_message(b"hello", 0).is_empty());
    }

    #[test]
    fn validate_empty_rejected() {
        assert!(!validate_message(b"", 0).is_empty());
    }

    #[test]
    fn validate_delete_empty_ok() {
        assert!(validate_message(b"", 5).is_empty());
    }

    #[test]
    fn validate_delta_valid() {
        let json = r#"{"type":"MessageDelete","message_id":[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1],"hlc":{"wall_clock_ms":100,"counter":0,"node_id":[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1]}}"#;
        assert!(validate_delta(json).is_empty());
    }

    #[test]
    fn validate_delta_invalid() {
        assert!(!validate_delta("not json").is_empty());
    }

    #[test]
    fn validate_batch_too_large() {
        let result = validate_delta_batch(1001);
        assert!(result.contains("too large"));
    }

    #[test]
    fn validate_batch_empty() {
        assert!(!validate_delta_batch(0).is_empty());
    }

    #[test]
    fn validate_batch_ok() {
        assert!(validate_delta_batch(500).is_empty());
    }
}

#[cfg(test)]
mod wasm_api_tests {
    use super::*;

    #[test]
    fn generate_key_package_succeeds() {
        let identity = b"test-device-001";
        let kp = generate_key_package(identity).expect("KeyPackage generation should succeed");
        assert!(!kp.is_empty(), "KeyPackage should not be empty");
    }

    #[test]
    fn validate_delta_rejects_invalid_type() {
        let json = r#"{"type":"InvalidType","foo":"bar"}"#;
        let err = validate_delta(json);
        assert!(!err.is_empty());
    }
}
