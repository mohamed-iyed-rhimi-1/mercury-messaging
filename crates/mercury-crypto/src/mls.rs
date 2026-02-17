//! MLS (RFC 9420) group manager — create groups, add/remove members, encrypt/decrypt.

use anyhow::{Context, Result, bail};
use openmls::prelude::*;
use openmls_basic_credential::SignatureKeyPair;
use openmls_rust_crypto::OpenMlsRustCrypto;
use std::collections::HashMap;
use tls_codec::{Deserialize as TlsDeserialize, Serialize as TlsSerialize};

/// Max group members (NASA Rule #2).
const MAX_GROUP_MEMBERS: usize = 1000;
/// Max message size in bytes (NASA Rule #2).
const MAX_MESSAGE_SIZE: usize = 65_536;

const CIPHERSUITE: Ciphersuite = Ciphersuite::MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519;

/// Manages MLS groups for a single identity (device).
pub struct MlsGroupManager {
    provider: OpenMlsRustCrypto,
    credential_with_key: CredentialWithKey,
    signer: SignatureKeyPair,
    groups: HashMap<Vec<u8>, MlsGroup>,
}

fn to_bytes<T: TlsSerialize>(val: &T) -> Result<Vec<u8>> {
    let mut buf = Vec::new();
    val.tls_serialize(&mut buf)
        .context("TLS serialize failed")?;
    Ok(buf)
}

impl MlsGroupManager {
    /// Create a new manager for the given identity bytes.
    ///
    /// # Panics
    /// Panics if `identity` is empty.
    ///
    /// # Errors
    /// Returns error if credential or key generation fails.
    pub fn new(identity: &[u8]) -> Result<Self> {
        assert!(!identity.is_empty(), "identity must not be empty");

        let provider = OpenMlsRustCrypto::default();
        let signer = SignatureKeyPair::new(CIPHERSUITE.signature_algorithm())
            .context("failed to generate signature keypair")?;
        signer
            .store(provider.storage())
            .context("failed to store signature keypair")?;

        let credential = BasicCredential::new(identity.to_vec());
        let credential_with_key = CredentialWithKey {
            credential: credential.into(),
            signature_key: signer.to_public_vec().into(),
        };

        Ok(Self {
            provider,
            credential_with_key,
            signer,
            groups: HashMap::new(),
        })
    }

    /// Generate a fresh `KeyPackage` for upload to the server.
    ///
    /// # Errors
    /// Returns error if key package generation fails.
    pub fn generate_key_package(&self) -> Result<Vec<u8>> {
        let kp = KeyPackage::builder()
            .build(
                CIPHERSUITE,
                &self.provider,
                &self.signer,
                self.credential_with_key.clone(),
            )
            .context("failed to build key package")?;

        to_bytes(kp.key_package())
    }

    /// Create a new MLS group (maps to a Mercury channel).
    ///
    /// # Panics
    /// Panics if `group_id` is empty.
    ///
    /// # Errors
    /// Returns error if group creation fails or group already exists.
    pub fn create_group(&mut self, group_id: &[u8]) -> Result<()> {
        assert!(!group_id.is_empty(), "group_id must not be empty");

        if self.groups.contains_key(group_id) {
            bail!("group already exists");
        }

        let group = MlsGroup::builder()
            .with_group_id(GroupId::from_slice(group_id))
            .use_ratchet_tree_extension(true)
            .build(
                &self.provider,
                &self.signer,
                self.credential_with_key.clone(),
            )
            .context("failed to create MLS group")?;

        self.groups.insert(group_id.to_vec(), group);
        Ok(())
    }

    /// Add a member to a group. Returns `(commit_bytes, welcome_bytes)`.
    ///
    /// # Errors
    /// Returns error if the group doesn't exist, member limit reached, or MLS operation fails.
    pub fn add_member(
        &mut self,
        group_id: &[u8],
        key_package_bytes: &[u8],
    ) -> Result<(Vec<u8>, Vec<u8>)> {
        let group = self.groups.get_mut(group_id).context("group not found")?;

        if group.members().count() >= MAX_GROUP_MEMBERS {
            bail!("group member limit ({MAX_GROUP_MEMBERS}) reached");
        }

        let kp_in = KeyPackageIn::tls_deserialize(&mut &*key_package_bytes)
            .context("failed to deserialize key package")?;
        let kp_verified = kp_in
            .validate(self.provider.crypto(), ProtocolVersion::Mls10)
            .context("key package validation failed")?;

        let (commit_msg, welcome, _group_info) = group
            .add_members(&self.provider, &self.signer, &[kp_verified])
            .context("failed to add member")?;

        group
            .merge_pending_commit(&self.provider)
            .context("failed to merge pending commit")?;

        let commit_bytes = to_bytes(&commit_msg)?;
        let welcome_bytes = to_bytes(&welcome)?;

        Ok((commit_bytes, welcome_bytes))
    }

    /// Remove a member by leaf index. Returns commit bytes.
    ///
    /// # Errors
    /// Returns error if group doesn't exist or MLS operation fails.
    pub fn remove_member(&mut self, group_id: &[u8], member_index: u32) -> Result<Vec<u8>> {
        let group = self.groups.get_mut(group_id).context("group not found")?;

        let leaf = LeafNodeIndex::new(member_index);
        let (commit_msg, _welcome, _group_info) = group
            .remove_members(&self.provider, &self.signer, &[leaf])
            .context("failed to remove member")?;

        group
            .merge_pending_commit(&self.provider)
            .context("failed to merge pending commit")?;

        to_bytes(&commit_msg)
    }

    /// Encrypt plaintext for a group. Returns MLS ciphertext bytes.
    ///
    /// # Panics
    /// Panics if `plaintext` exceeds `MAX_MESSAGE_SIZE`.
    ///
    /// # Errors
    /// Returns error if group doesn't exist or encryption fails.
    pub fn encrypt(&mut self, group_id: &[u8], plaintext: &[u8]) -> Result<Vec<u8>> {
        assert!(
            plaintext.len() <= MAX_MESSAGE_SIZE,
            "message exceeds {MAX_MESSAGE_SIZE} bytes"
        );

        let group = self.groups.get_mut(group_id).context("group not found")?;

        let mls_msg = group
            .create_message(&self.provider, &self.signer, plaintext)
            .context("failed to encrypt message")?;

        to_bytes(&mls_msg)
    }

    /// Decrypt an MLS ciphertext. Returns plaintext bytes.
    ///
    /// # Errors
    /// Returns error if group doesn't exist, ciphertext invalid, or decryption fails.
    pub fn decrypt(&mut self, group_id: &[u8], ciphertext: &[u8]) -> Result<Vec<u8>> {
        let group = self.groups.get_mut(group_id).context("group not found")?;

        let mls_msg_in = MlsMessageIn::tls_deserialize(&mut &*ciphertext)
            .context("failed to deserialize MLS message")?;

        let protocol_msg = mls_msg_in
            .try_into_protocol_message()
            .map_err(|e| anyhow::anyhow!("not a protocol message: {e:?}"))?;

        let processed = group
            .process_message(&self.provider, protocol_msg)
            .context("failed to process MLS message")?;

        match processed.into_content() {
            ProcessedMessageContent::ApplicationMessage(app_msg) => Ok(app_msg.into_bytes()),
            _ => bail!("expected application message"),
        }
    }

    /// Join a group from a Welcome message. Returns the `group_id`.
    ///
    /// # Errors
    /// Returns error if welcome is invalid or join fails.
    pub fn process_welcome(&mut self, welcome_bytes: &[u8]) -> Result<Vec<u8>> {
        let mls_msg_in = MlsMessageIn::tls_deserialize(&mut &*welcome_bytes)
            .context("failed to deserialize welcome")?;

        let welcome = mls_msg_in
            .into_welcome()
            .ok_or_else(|| anyhow::anyhow!("not a welcome message"))?;

        let staged = StagedWelcome::new_from_welcome(
            &self.provider,
            &MlsGroupJoinConfig::default(),
            welcome,
            None,
        )
        .context("failed to stage welcome")?;

        let group = staged
            .into_group(&self.provider)
            .context("failed to join group from welcome")?;

        let group_id = group.group_id().as_slice().to_vec();
        self.groups.insert(group_id.clone(), group);
        Ok(group_id)
    }

    /// Process a Commit message (member add/remove/update).
    ///
    /// # Errors
    /// Returns error if group doesn't exist or commit is invalid.
    pub fn process_commit(&mut self, group_id: &[u8], commit_bytes: &[u8]) -> Result<()> {
        let group = self.groups.get_mut(group_id).context("group not found")?;

        let mls_msg_in = MlsMessageIn::tls_deserialize(&mut &*commit_bytes)
            .context("failed to deserialize commit")?;

        let protocol_msg = mls_msg_in
            .try_into_protocol_message()
            .map_err(|e| anyhow::anyhow!("not a protocol message: {e:?}"))?;

        let processed = group
            .process_message(&self.provider, protocol_msg)
            .context("failed to process commit")?;

        match processed.into_content() {
            ProcessedMessageContent::StagedCommitMessage(staged_commit) => {
                group
                    .merge_staged_commit(&self.provider, *staged_commit)
                    .context("failed to merge staged commit")?;
                Ok(())
            }
            _ => bail!("expected commit message"),
        }
    }

    /// Number of members in a group.
    pub fn member_count(&self, group_id: &[u8]) -> Option<usize> {
        self.groups.get(group_id).map(|g| g.members().count())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn create_group_and_encrypt() {
        let mut alice = MlsGroupManager::new(b"alice").unwrap();
        alice.create_group(b"chan1").unwrap();
        let ct = alice.encrypt(b"chan1", b"hello").unwrap();
        assert!(!ct.is_empty());
    }

    #[test]
    fn two_party_encrypt_decrypt() {
        let mut alice = MlsGroupManager::new(b"alice").unwrap();
        let mut bob = MlsGroupManager::new(b"bob").unwrap();

        let bob_kp = bob.generate_key_package().unwrap();
        alice.create_group(b"chan1").unwrap();
        let (_commit, welcome) = alice.add_member(b"chan1", &bob_kp).unwrap();

        let group_id = bob.process_welcome(&welcome).unwrap();
        assert_eq!(group_id, b"chan1");

        let ct = alice.encrypt(b"chan1", b"hello bob").unwrap();
        let pt = bob.decrypt(b"chan1", &ct).unwrap();
        assert_eq!(pt, b"hello bob");

        let ct2 = bob.encrypt(b"chan1", b"hi alice").unwrap();
        let pt2 = alice.decrypt(b"chan1", &ct2).unwrap();
        assert_eq!(pt2, b"hi alice");
    }

    #[test]
    fn three_party_group() {
        let mut alice = MlsGroupManager::new(b"alice").unwrap();
        let mut bob = MlsGroupManager::new(b"bob").unwrap();
        let mut carol = MlsGroupManager::new(b"carol").unwrap();

        let bob_kp = bob.generate_key_package().unwrap();
        let carol_kp = carol.generate_key_package().unwrap();

        alice.create_group(b"group3").unwrap();

        let (_commit1, welcome1) = alice.add_member(b"group3", &bob_kp).unwrap();
        bob.process_welcome(&welcome1).unwrap();

        let (commit2, welcome2) = alice.add_member(b"group3", &carol_kp).unwrap();
        bob.process_commit(b"group3", &commit2).unwrap();
        carol.process_welcome(&welcome2).unwrap();

        assert_eq!(alice.member_count(b"group3"), Some(3));
        assert_eq!(bob.member_count(b"group3"), Some(3));
        assert_eq!(carol.member_count(b"group3"), Some(3));

        let ct = alice.encrypt(b"group3", b"hello everyone").unwrap();
        assert_eq!(bob.decrypt(b"group3", &ct).unwrap(), b"hello everyone");
    }

    #[test]
    fn generate_key_package() {
        let mgr = MlsGroupManager::new(b"device1").unwrap();
        let kp = mgr.generate_key_package().unwrap();
        assert!(!kp.is_empty());
        let kp2 = mgr.generate_key_package().unwrap();
        assert_ne!(kp, kp2);
    }

    #[test]
    fn group_not_found_errors() {
        let mut mgr = MlsGroupManager::new(b"test").unwrap();
        assert!(mgr.encrypt(b"nonexistent", b"hello").is_err());
        assert!(mgr.decrypt(b"nonexistent", b"garbage").is_err());
    }

    #[test]
    fn duplicate_group_errors() {
        let mut mgr = MlsGroupManager::new(b"test").unwrap();
        mgr.create_group(b"g1").unwrap();
        assert!(mgr.create_group(b"g1").is_err());
    }

    #[test]
    fn invalid_ciphertext_errors() {
        let mut alice = MlsGroupManager::new(b"alice").unwrap();
        alice.create_group(b"chan").unwrap();
        assert!(alice.decrypt(b"chan", b"not valid mls").is_err());
    }

    #[test]
    #[should_panic(expected = "message exceeds")]
    fn oversized_message_panics() {
        let mut mgr = MlsGroupManager::new(b"test").unwrap();
        mgr.create_group(b"g").unwrap();
        let big = vec![0u8; MAX_MESSAGE_SIZE + 1];
        let _ = mgr.encrypt(b"g", &big);
    }

    #[test]
    fn welcome_flow() {
        let mut alice = MlsGroupManager::new(b"alice").unwrap();
        let mut bob = MlsGroupManager::new(b"bob").unwrap();

        let bob_kp = bob.generate_key_package().unwrap();
        alice.create_group(b"welcome_test").unwrap();

        let (_commit, welcome) = alice.add_member(b"welcome_test", &bob_kp).unwrap();
        let gid = bob.process_welcome(&welcome).unwrap();
        assert_eq!(gid, b"welcome_test");
        assert_eq!(bob.member_count(b"welcome_test"), Some(2));
    }

    #[test]
    fn remove_member_cannot_decrypt() {
        let mut alice = MlsGroupManager::new(b"alice_rm").unwrap();
        let mut bob = MlsGroupManager::new(b"bob_rm").unwrap();

        let bob_kp = bob.generate_key_package().unwrap();
        alice.create_group(b"rm_group").unwrap();

        let (_commit, welcome) = alice.add_member(b"rm_group", &bob_kp).unwrap();
        let bob_gid = bob.process_welcome(&welcome).unwrap();

        // Both can encrypt/decrypt before removal
        let ct = alice.encrypt(b"rm_group", b"before removal").unwrap();
        let pt = bob.decrypt(&bob_gid, &ct).unwrap();
        assert_eq!(pt, b"before removal");

        // Alice removes Bob (leaf index 1)
        let _remove_commit = alice.remove_member(b"rm_group", 1).unwrap();

        // Alice encrypts after removal — Bob cannot decrypt
        let ct_after = alice.encrypt(b"rm_group", b"after removal").unwrap();
        assert!(bob.decrypt(&bob_gid, &ct_after).is_err());
    }
}
