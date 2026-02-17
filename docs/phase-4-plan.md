# Phase 4: End-to-End Encryption (MLS) — Implementation Plan

## Goal
Replace `NoopEncryptor` with real MLS (RFC 9420) encryption via `openmls`. After
this phase, all messages are end-to-end encrypted — the server is cryptographically
unable to read message content. Encryption happens in Rust, exposed to Elixir via NIFs.

## Prerequisites
- Phase 3 complete (120 tests, all quality gates green)
- `mercury-crypto` crate exists with `Encryptor` trait + `NoopEncryptor`
- `encrypt_message`/`decrypt_message` NIFs already wired in gateway
- Docker services running (PostgreSQL for KeyPackage storage)

## Scope Decisions
- **In scope**: MLS group lifecycle (create/add/remove/encrypt/decrypt), KeyPackage
  management, key rotation, Device schema, NIF bridge, gateway integration
- **Deferred to Phase 7**: Sealed sender (needs edge infrastructure), key transparency
  Merkle tree (needs audit infrastructure), formal security audit
- **Deferred to Phase 5**: Client-side MLS state storage (SQLCipher) — server only
  manages KeyPackages and relays MLS messages, never holds group state
- **Server role**: The server is a "delivery service" in MLS terms — it stores
  KeyPackages, relays MLS handshake messages (Welcome, Commit), and fans out
  encrypted application messages. It never sees plaintext or group keys.

## Key Design Decision: Where MLS State Lives

MLS group state (epoch secrets, ratchet trees) lives **client-side only**. The server:
1. Stores KeyPackages (public, uploaded by devices)
2. Relays MLS handshake messages (Welcome, Commit) between clients
3. Stores encrypted ciphertext in ScyllaDB (opaque blobs)
4. Never holds group secrets

This means Phase 4 focuses on:
- The Rust `mercury-crypto` crate with full MLS operations
- NIFs that the **SDK** (Phase 6) will call client-side
- Server-side KeyPackage CRUD (PostgreSQL + Elixir)
- Server-side MLS message relay (gateway channels)

For testing, we simulate both client and server in the same process.

---

## Steps

### 4.1 — Add OpenMLS Dependencies (Day 1)

Add to `crates/mercury-crypto/Cargo.toml`:
```toml
openmls = { version = "0.7", features = ["test-utils"] }
openmls_rust_crypto = "0.5"
openmls_basic_credential = { version = "0.5", features = ["clonable"] }
openmls_memory_storage = "0.5"
```

The `test-utils` feature is for testing only. Production builds use default features.
`openmls_rust_crypto` provides the crypto backend (X25519, AES-128-GCM, SHA-256, Ed25519).
`openmls_memory_storage` for in-memory state during tests (SDK will use SQLite in Phase 6).

Verify: `cargo build -p mercury-crypto` compiles clean.

### 4.2 — MLS Group Manager (Days 2–5)

Implement `MlsGroupManager` in `mercury-crypto` — the core MLS operations.

Deliverables in `crates/mercury-crypto/src/mls.rs`:

- `MlsGroupManager::new(identity: &[u8]) -> Result<Self>`
  - Creates a credential + signing key for this identity
  - Stores the OpenMLS provider (crypto + storage)

- `MlsGroupManager::generate_key_package() -> Result<KeyPackageBytes>`
  - Generates a fresh KeyPackage for upload to server
  - Ciphersuite: MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519

- `MlsGroupManager::create_group(group_id: &[u8]) -> Result<()>`
  - Creates a new MLS group (maps to a Mercury channel)
  - Stores group state internally

- `MlsGroupManager::add_member(group_id: &[u8], key_package: &[u8]) -> Result<(Vec<u8>, Vec<u8>)>`
  - Returns `(commit_bytes, welcome_bytes)` — commit for existing members, welcome for new member
  - Merges pending commit locally

- `MlsGroupManager::remove_member(group_id: &[u8], member_index: u32) -> Result<Vec<u8>>`
  - Returns commit bytes for fan-out
  - Merges pending commit locally

- `MlsGroupManager::encrypt(group_id: &[u8], plaintext: &[u8]) -> Result<Vec<u8>>`
  - Encrypts a message for the group
  - Returns MLS ciphertext bytes

- `MlsGroupManager::decrypt(group_id: &[u8], ciphertext: &[u8]) -> Result<Vec<u8>>`
  - Decrypts a received MLS message
  - Returns plaintext bytes

- `MlsGroupManager::process_welcome(welcome: &[u8]) -> Result<Vec<u8>>`
  - Joins a group from a Welcome message
  - Returns the group_id

- `MlsGroupManager::process_commit(group_id: &[u8], commit: &[u8]) -> Result<()>`
  - Applies a Commit (member add/remove/update) to local group state

Constants (NASA Rule #2):
- `MAX_GROUP_MEMBERS: usize = 1000`
- `MAX_MESSAGE_SIZE: usize = 65536` (64KB)
- `MAX_KEY_PACKAGES_PER_DEVICE: usize = 100`

Tests:
- Create group → encrypt → decrypt roundtrip
- Two-party: Alice creates group, adds Bob, both encrypt/decrypt
- Three-party: Alice + Bob + Carol, all can decrypt each other's messages
- Remove member: removed member cannot decrypt new messages
- Process welcome: new member joins and can decrypt
- Forward secrecy: old epoch keys cannot decrypt new messages
- Invalid ciphertext returns error (not panic)
- Max message size enforced

Benchmarks:
- `create_group`: target <5ms
- `encrypt`: target <2ms
- `decrypt`: target <2ms
- `add_member`: target <10ms
- `generate_key_package`: target <5ms

### 4.3 — Update Encryptor Trait (Day 5)

Update `EncryptionConfig` to support MLS:
```rust
pub enum EncryptionConfig {
    Noop,
    Mls { identity: Vec<u8> },
}
```

The existing `Encryptor` trait stays for simple encrypt/decrypt. `MlsGroupManager`
is the full-featured API for group operations. Both coexist — `Encryptor` for
backward compat, `MlsGroupManager` for real E2EE.

### 4.4 — Device Schema + KeyPackage Storage (Days 6–7)

Server-side: Devices upload KeyPackages so other users can add them to groups.

Deliverables:
- `Persistence.Schema.Device` — Ecto schema (the `devices` table already exists in PostgreSQL)
  - Fields: device_id, tenant_id, user_id, device_name, platform, push_token, last_seen_at
  - Add `mls_key_package BYTEA` column to devices table (migration)
- `Persistence.KeyPackages` — Elixir module for KeyPackage CRUD:
  - `upload(tenant_id, device_id, key_package_bytes) -> :ok`
  - `fetch(tenant_id, user_id) -> {:ok, [key_package_bytes]}` (one per device)
  - `consume(tenant_id, device_id) -> {:ok, key_package_bytes}` (fetch + delete, one-time use)
- Schema changeset tests (unit, no DB required)
- Integration test: upload → fetch → consume → fetch returns empty

### 4.5 — NIF Bridge: MLS Operations (Days 8–10)

Expose `MlsGroupManager` to Elixir via Rustler NIFs.

New NIFs in `mercury-nif`:
- `mls_create_identity(identity_bytes) -> {:ok, state_ref} | {:error, reason}`
  - Creates an MlsGroupManager, returns opaque reference
  - Runs on DirtyCpu scheduler
- `mls_generate_key_package(state_ref) -> {:ok, key_package_bytes} | {:error, reason}`
- `mls_create_group(state_ref, group_id) -> :ok | {:error, reason}`
- `mls_add_member(state_ref, group_id, key_package) -> {:ok, commit, welcome} | {:error, reason}`
- `mls_remove_member(state_ref, group_id, member_index) -> {:ok, commit} | {:error, reason}`
- `mls_encrypt(state_ref, group_id, plaintext) -> {:ok, ciphertext} | {:error, reason}`
- `mls_decrypt(state_ref, group_id, ciphertext) -> {:ok, plaintext} | {:error, reason}`
- `mls_process_welcome(state_ref, welcome) -> {:ok, group_id} | {:error, reason}`
- `mls_process_commit(state_ref, group_id, commit) -> :ok | {:error, reason}`

State management: `MlsGroupManager` is stored in a Rust `ResourceArc<Mutex<MlsGroupManager>>`
so it can be held across NIF calls. The BEAM holds the reference; Rust owns the memory.

Update existing `encrypt_message`/`decrypt_message` NIFs to delegate to MLS when
configured (feature flag). Default remains Noop for backward compat during transition.

### 4.6 — Gateway MLS Message Relay (Days 10–12)

The gateway relays MLS handshake messages between clients. It does NOT perform
encryption/decryption — that's client-side.

New channel events in `MessageChannel`:
- `mls:key_package` — Client uploads a KeyPackage for their device
  - Server stores in PostgreSQL via `Persistence.KeyPackages.upload/3`
- `mls:fetch_key_packages` — Client requests KeyPackages for a user (to add them to a group)
  - Server returns list from PostgreSQL via `Persistence.KeyPackages.fetch/2`
- `mls:commit` — Client sends a Commit message (member add/remove/update)
  - Server fans out to all group members via PubSub
  - Server stores in ScyllaDB as a system message (content_type = 6)
- `mls:welcome` — Client sends a Welcome message for a newly added member
  - Server delivers to the specific user via `{tenant_id}:user:{user_id}` topic

The existing `msg:send` flow stays the same — the `encrypted_content` field in
ScyllaDB already stores opaque bytes. The only difference is those bytes are now
real MLS ciphertext instead of Noop passthrough.

### 4.7 — Integration Tests (Days 12–14)

Test scenarios (all in Rust, no Docker needed):
1. Full lifecycle: create identity → generate key package → create group → add member → encrypt → decrypt
2. Three-party group: Alice creates, adds Bob and Carol, all three exchange messages
3. Member removal: Remove Bob → Bob cannot decrypt new messages → Alice and Carol still can
4. Welcome flow: Alice creates group → adds Bob via Welcome → Bob joins and decrypts
5. Key rotation: After add/remove, new epoch keys work, old don't
6. Error cases: decrypt with wrong group, invalid ciphertext, oversized message

Test scenarios (Elixir, integration, require Docker):
7. KeyPackage upload → fetch → consume roundtrip via PostgreSQL
8. MLS NIF: create identity → generate key package → create group → encrypt → decrypt

### 4.8 — ADR (Day 14)
- ADR-007: "Why MLS over Signal Protocol for group encryption"

---

## Dependencies (Rust — mercury-crypto)

Add to `crates/mercury-crypto/Cargo.toml`:
```toml
openmls = { version = "0.7", features = ["test-utils"] }
openmls_rust_crypto = "0.5"
openmls_basic_credential = { version = "0.5", features = ["clonable"] }
openmls_memory_storage = "0.5"
```

## File Inventory (New/Modified)

### New Files
```
crates/mercury-crypto/src/mls.rs                       — MlsGroupManager
apps/persistence/lib/persistence/key_packages.ex        — KeyPackage CRUD
apps/persistence/lib/persistence/schema/device.ex       — Device Ecto schema
apps/persistence/priv/repo/migrations/..._add_mls.exs  — Add mls_key_package column
docs/adr/007-mls-over-signal.md
```

### Modified Files
```
crates/mercury-crypto/Cargo.toml                        — Add openmls deps
crates/mercury-crypto/src/lib.rs                        — Add mls module, update EncryptionConfig
crates/mercury-nif/Cargo.toml                           — Add mercury-crypto with mls
crates/mercury-nif/src/lib.rs                           — Add MLS NIF functions
apps/gateway/lib/gateway/message_channel.ex             — Add mls:* channel events
apps/persistence/test/persistence_integration_test.exs  — Add KeyPackage + MLS NIF tests
```

---

## Acceptance Criteria

| # | Criterion | Verification |
|---|-----------|-------------|
| 1 | MLS encrypt/decrypt roundtrip works | Rust unit test |
| 2 | Multi-party group (3+ members) all decrypt | Rust unit test |
| 3 | Removed member cannot decrypt new messages | Rust unit test |
| 4 | Welcome flow: new member joins and decrypts | Rust unit test |
| 5 | encrypt <2ms, decrypt <2ms | Criterion benchmark |
| 6 | KeyPackage upload/fetch/consume works | Elixir integration test |
| 7 | MLS NIFs work from Elixir | Elixir integration test |
| 8 | Gateway relays mls:commit and mls:welcome | Elixir unit test |
| 9 | NoopEncryptor still works (backward compat) | Existing tests pass |
| 10 | ADR-007 written | File exists |
| 11 | All existing tests still pass (120+) | Full quality gate |

## Quality Gates (same as Phase 3)
- Rust: clippy zero warnings, fmt clean, all tests pass, benchmarks under targets
- Elixir: dialyzer zero warnings, credo strict zero issues, format clean, all tests pass
- Integration tests pass with Docker running

---

## Timeline Estimate
- Days 1: OpenMLS deps + verify build
- Days 2–5: MlsGroupManager + Rust tests + benchmarks
- Day 5: Update EncryptionConfig
- Days 6–7: Device schema + KeyPackage storage
- Days 8–10: NIF bridge
- Days 10–12: Gateway MLS relay
- Days 12–14: Integration tests + ADR

Total: ~14 working days
