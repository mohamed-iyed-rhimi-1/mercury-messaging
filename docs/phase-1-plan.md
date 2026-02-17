# Phase 1: Core Message Domain in Rust — Implementation Plan

**Timeline:** Weeks 3–8 (20 working days)
**Goal:** Pure domain logic — types, validation, CRDTs, crypto stub, benchmarks. No networking, no databases. Everything tested with property-based tests and benchmarked with Criterion.

**Prerequisite:** Phase 0 complete (`cargo check && cargo test` green).

---

## Day-by-Day Breakdown

### Days 1–4: `mercury-core` — Domain Types (Step 1.1)

**Day 1 — Newtype IDs + TenantId**

Add `ulid` to workspace dependencies:

```toml
# Cargo.toml (workspace root) — add to [workspace.dependencies]
ulid = { version = "1", features = ["serde"] }
```

```rust
// crates/mercury-core/src/ids.rs

use bytes::Bytes;
use serde::{Deserialize, Serialize};
use std::fmt;
use std::str::FromStr;
use uuid::Uuid;

/// Tenant identifier. Present on EVERY domain object.
/// Multi-tenancy is enforced at the type level — you cannot construct
/// a Message, Channel, or User without a TenantId.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct TenantId(Uuid);

/// ULID-based message identifier. Sortable, embeds creation timestamp.
/// Chosen over UUIDv7 because ULIDs are case-insensitive and have a
/// canonical string representation (Crockford Base32). See ADR-002.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
pub struct MessageId(ulid::Ulid);

/// Channel identifier. UUIDv4.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct ChannelId(Uuid);

/// User identifier. UUIDv4.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct UserId(Uuid);

/// Device identifier. UUIDv4.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct DeviceId(Uuid);
```

Each ID type needs:
- `new()` constructor (generates fresh ID)
- `from_bytes([u8; 16])` for deserialization from Cap'n Proto `Data` fields
- `as_bytes() -> &[u8; 16]` for serialization
- `Display` and `FromStr` implementations
- `MessageId::timestamp() -> u64` to extract embedded creation time (millis)
- Unit tests: roundtrip (new → display → parse → equal), ordering (MessageId), byte conversion

NASA Rules applied:
- Rule #5: `assert!` in `from_bytes` that input is exactly 16 bytes
- Rule #7: All constructors return the type directly (infallible) or `Result` (fallible parse)
- Rule #8: No macros — each impl is explicit

**Day 2 — TimeBucket + TenantContext**

```rust
// crates/mercury-core/src/time_bucket.rs

/// Time bucket for ScyllaDB partition keys.
/// bucket_id = unix_epoch_days / 10
/// New partition every 10 days per channel. Prevents unbounded partition growth.
/// (NASA Rule #2: fixed upper bound on partition size)
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct TimeBucket(u32);

impl TimeBucket {
    /// Compute bucket from Unix timestamp in milliseconds.
    pub fn from_timestamp_ms(ts_ms: u64) -> Self { /* epoch_days / 10 */ }

    /// Compute bucket from a MessageId (extracts embedded timestamp).
    pub fn from_message_id(id: &MessageId) -> Self { /* id.timestamp() → from_timestamp_ms */ }

    /// Get the bucket_id value for use in CQL queries.
    pub fn as_i32(self) -> i32 { /* self.0 as i32 */ }
}
```

```rust
// crates/mercury-core/src/tenant.rs

/// Tenant-scoped configuration. Threaded through all service calls.
/// Every operation checks these limits before proceeding.
#[derive(Debug, Clone)]
pub struct TenantContext {
    pub tenant_id: TenantId,
    pub max_users: u32,
    pub max_channels: u32,
    pub max_file_size_mb: u32,
    pub rate_limit_per_user: u32,  // messages per second
    pub signup_mode: SignupMode,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SignupMode {
    Open,
    InviteOnly,
    Waitlist,
}
```

Tests:
- `TimeBucket::from_timestamp_ms` — known timestamps map to expected buckets
- Bucket boundary: timestamps 10 days apart produce different buckets
- Same bucket: timestamps within same 10-day window produce same bucket
- `TenantContext` construction with all fields

**Day 3 — Message + Channel + ContentType**

```rust
// crates/mercury-core/src/message.rs

/// Content type discriminator. Maps to Cap'n Proto ContentType enum.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ContentType {
    Text = 0,
    Image = 1,
    File = 2,
    Reaction = 3,
    Edit = 4,
    Delete = 5,
}

/// A message in the system. The `encrypted_content` is opaque to the server.
/// Only clients with the MLS group key can decrypt it.
#[derive(Debug, Clone)]
pub struct Message {
    pub tenant_id: TenantId,
    pub channel_id: ChannelId,
    pub id: MessageId,
    pub sender_id: UserId,
    pub encrypted_content: Bytes,   // Opaque E2EE payload
    pub content_type: ContentType,
    pub reply_to: Option<MessageId>,
    pub created_at: u64,            // Unix millis
    pub server_received_at: Option<u64>,
}
```

```rust
// crates/mercury-core/src/channel.rs

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ChannelType {
    Dm = 0,
    Group = 1,
    Broadcast = 2,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MemberRole {
    Member = 0,
    Admin = 1,
    Owner = 2,
}

#[derive(Debug, Clone)]
pub struct Channel {
    pub tenant_id: TenantId,
    pub id: ChannelId,
    pub channel_type: ChannelType,
    pub name: Option<String>,
    pub created_by: UserId,
    pub created_at: u64,
}
```

Validation functions (NASA Rule #5 — assertions on all invariants):
- `Message::validate(&self) -> Result<()>` — content not empty, content_type matches payload, reply_to != self.id
- `Channel::validate(&self) -> Result<()>` — DM has no name, Group/Broadcast requires name, name length ≤ 128

**Day 4 — Error types + module structure + lib.rs wiring**

```rust
// crates/mercury-core/src/error.rs

#[derive(Debug, thiserror::Error)]
pub enum CoreError {
    #[error("invalid message: {reason}")]
    InvalidMessage { reason: String },

    #[error("invalid channel: {reason}")]
    InvalidChannel { reason: String },

    #[error("invalid id format: {0}")]
    InvalidId(String),

    #[error("tenant context required")]
    MissingTenantContext,

    #[error("rate limit exceeded: {limit}/s")]
    RateLimitExceeded { limit: u32 },
}
```

Wire up `lib.rs`:
```rust
// crates/mercury-core/src/lib.rs
pub mod ids;
pub mod time_bucket;
pub mod tenant;
pub mod message;
pub mod channel;
pub mod error;

// Re-exports for ergonomic API
pub use ids::{TenantId, MessageId, ChannelId, UserId, DeviceId};
pub use time_bucket::TimeBucket;
pub use tenant::{TenantContext, SignupMode};
pub use message::{Message, ContentType};
pub use channel::{Channel, ChannelType, MemberRole};
pub use error::CoreError;
```

Tests for Day 4:
- Construct a `Message` with all fields, validate passes
- Construct invalid messages (empty content, self-reply), validate fails
- Error display strings are human-readable

---

### Days 5–10: `mercury-crdt` — CRDT Primitives (Step 1.2)

**Day 5 — HybridLogicalClock**

```rust
// crates/mercury-crdt/src/hlc.rs

/// Hybrid Logical Clock for distributed event ordering.
/// Combines wall clock (physical time) with a logical counter
/// to provide a total order across all nodes.
///
/// Ordering: (wall_clock_ms, counter, node_id)
/// - Same physical time → counter breaks tie
/// - Same counter → node_id breaks tie (arbitrary but deterministic)
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Hlc {
    pub wall_clock_ms: u64,
    pub counter: u32,
    pub node_id: [u8; 16],
}

impl Hlc {
    /// Create a new HLC from the current wall clock.
    pub fn now(node_id: [u8; 16]) -> Self { /* ... */ }

    /// Advance the clock (local event).
    /// Takes max(wall_clock, system_time), increments counter if same ms.
    pub fn tick(&mut self) { /* ... */ }

    /// Merge with a received remote clock.
    /// new_wall = max(local, remote, system_time)
    /// counter logic per HLC paper.
    pub fn merge(&mut self, remote: &Hlc) { /* ... */ }
}

impl Ord for Hlc { /* (wall_clock_ms, counter, node_id) */ }
```

Tests:
- `tick()` always advances (monotonic)
- `merge()` produces clock ≥ both inputs
- Concurrent events on different nodes get different HLCs
- Property test: for any two HLCs, `Ord` is total (antisymmetric, transitive)

**Day 6 — Mergeable trait + GCounter**

```rust
// crates/mercury-crdt/src/traits.rs

/// All CRDTs implement this trait.
/// Laws (verified by property tests):
///   1. Commutative: merge(a, b) == merge(b, a)
///   2. Associative: merge(merge(a, b), c) == merge(a, merge(b, c))
///   3. Idempotent:  merge(a, a) == a
pub trait Mergeable {
    fn merge(&mut self, other: &Self);
}
```

```rust
// crates/mercury-crdt/src/gcounter.rs

/// Grow-only counter. Used for read receipt counts.
/// Each node has its own counter slot. Total = sum of all slots.
/// Merge = element-wise max.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GCounter {
    counts: BTreeMap<[u8; 16], u64>,  // node_id → count
}

impl GCounter {
    pub fn new() -> Self { /* ... */ }
    pub fn increment(&mut self, node_id: [u8; 16]) { /* ... */ }
    pub fn value(&self) -> u64 { /* sum of all counts */ }
}

impl Mergeable for GCounter { /* element-wise max */ }
```

Tests + property tests:
- Increment increases value by 1
- Merge of two counters = max per node
- Property: commutativity, associativity, idempotency

**Day 7 — LWWRegister**

```rust
// crates/mercury-crdt/src/lww_register.rs

/// Last-Writer-Wins Register. Used for user profile fields, channel names.
/// The value with the highest HLC timestamp wins on merge.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LwwRegister<T> {
    value: T,
    timestamp: Hlc,
}

impl<T> LwwRegister<T> {
    pub fn new(value: T, timestamp: Hlc) -> Self { /* ... */ }
    pub fn set(&mut self, value: T, timestamp: Hlc) { /* only if timestamp > self.timestamp */ }
    pub fn get(&self) -> &T { /* ... */ }
}

impl<T: Clone + PartialEq> Mergeable for LwwRegister<T> { /* higher HLC wins */ }
```

Tests:
- Set with newer timestamp updates value
- Set with older timestamp is ignored
- Property: commutativity, associativity, idempotency

**Day 8 — ORSet**

```rust
// crates/mercury-crdt/src/orset.rs

/// Observed-Remove Set. Used for channel membership.
/// Supports concurrent add + remove without conflict.
/// Add wins over concurrent remove (availability bias).
///
/// Implementation: each element tagged with a unique "dot" (node_id, counter).
/// Add creates a new dot. Remove removes all known dots for that element.
/// Merge = union of dots.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ORSet<T: Eq + Hash + Clone> {
    entries: HashMap<T, BTreeSet<Dot>>,
    // Dot = (node_id, sequence_number)
}

impl<T: Eq + Hash + Clone> ORSet<T> {
    pub fn new() -> Self { /* ... */ }
    pub fn add(&mut self, value: T, node_id: [u8; 16]) { /* ... */ }
    pub fn remove(&mut self, value: &T) { /* ... */ }
    pub fn contains(&self, value: &T) -> bool { /* ... */ }
    pub fn elements(&self) -> impl Iterator<Item = &T> { /* ... */ }
    pub fn len(&self) -> usize { /* ... */ }
}

impl<T: Eq + Hash + Clone> Mergeable for ORSet<T> { /* union of dot sets */ }
```

Tests:
- Add then remove → empty
- Concurrent add on two nodes → both present after merge
- Concurrent add + remove → add wins
- Property: commutativity, associativity, idempotency

**Day 9 — ReactionMap**

```rust
// crates/mercury-crdt/src/reaction_map.rs

/// Specialized CRDT for message reactions.
/// Internally an ORSet<(UserId, Emoji)> per message.
/// Enforces: one reaction per user per emoji (set semantics = natural dedup).
///
/// This is "Option B" from the architecture doc — denormalized + CRDT.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReactionMap {
    reactions: ORSet<(UserId, String)>,  // (user, emoji) pairs
}

impl ReactionMap {
    pub fn new() -> Self { /* ... */ }
    pub fn add_reaction(&mut self, user: UserId, emoji: String, node_id: [u8; 16]) { /* ... */ }
    pub fn remove_reaction(&mut self, user: &UserId, emoji: &str) { /* ... */ }
    pub fn reactions_for_emoji(&self, emoji: &str) -> Vec<UserId> { /* ... */ }
    pub fn user_reactions(&self, user: &UserId) -> Vec<String> { /* ... */ }
    pub fn counts(&self) -> BTreeMap<String, usize> { /* emoji → count */ }
}

impl Mergeable for ReactionMap { /* delegates to inner ORSet */ }
```

Tests:
- Add reaction, verify in counts
- Same user same emoji twice → still count 1 (set dedup)
- Remove reaction, verify gone
- Two users react same emoji → count 2
- Merge from two nodes, reactions union correctly
- Property: commutativity, associativity, idempotency

**Day 10 — MessageLog**

```rust
// crates/mercury-crdt/src/message_log.rs

/// Append-only CRDT for message ordering.
/// Messages keyed by HLC — total order guaranteed.
/// Supports delta-state sync: "give me everything after HLC X".
///
/// Bounded: max 100,000 entries per log (NASA Rule #2).
/// Older entries compacted/archived when limit reached.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MessageLog {
    entries: BTreeMap<Hlc, Bytes>,  // HLC → encrypted message bytes
}

const MAX_LOG_ENTRIES: usize = 100_000;  // NASA Rule #2

impl MessageLog {
    pub fn new() -> Self { /* ... */ }
    pub fn append(&mut self, hlc: Hlc, data: Bytes) -> Result<(), CrdtError> { /* ... */ }
    pub fn entries_after(&self, since: &Hlc) -> Vec<(&Hlc, &Bytes)> { /* delta sync */ }
    pub fn len(&self) -> usize { /* ... */ }
    pub fn latest_hlc(&self) -> Option<&Hlc> { /* ... */ }
}

impl Mergeable for MessageLog { /* union of entries, capped at MAX_LOG_ENTRIES */ }
```

Tests:
- Append and retrieve in order
- `entries_after` returns only newer entries (delta sync)
- Merge two logs → union, sorted by HLC
- Exceeding `MAX_LOG_ENTRIES` returns error or truncates oldest
- Property: commutativity, associativity, idempotency

Wire up `mercury-crdt/src/lib.rs`:
```rust
pub mod hlc;
pub mod traits;
pub mod gcounter;
pub mod lww_register;
pub mod orset;
pub mod reaction_map;
pub mod message_log;
pub mod error;

pub use hlc::Hlc;
pub use traits::Mergeable;
pub use gcounter::GCounter;
pub use lww_register::LwwRegister;
pub use orset::ORSet;
pub use reaction_map::ReactionMap;
pub use message_log::MessageLog;
```

---

### Days 11–12: `mercury-crypto` Stub (Step 1.3)

**Day 11 — Encryptor trait + NoopEncryptor**

```rust
// crates/mercury-crypto/src/lib.rs

/// Encryption backend trait. Swappable between Noop (dev) and MLS (prod).
pub trait Encryptor: Send + Sync {
    fn encrypt(&self, plaintext: &[u8]) -> Result<Vec<u8>>;
    fn decrypt(&self, ciphertext: &[u8]) -> Result<Vec<u8>>;
}

/// Identity encryptor for development and testing.
/// Passes data through unchanged. Replaced by MLS in Phase 4.
pub struct NoopEncryptor;

impl Encryptor for NoopEncryptor {
    fn encrypt(&self, plaintext: &[u8]) -> Result<Vec<u8>> {
        Ok(plaintext.to_vec())
    }
    fn decrypt(&self, ciphertext: &[u8]) -> Result<Vec<u8>> {
        Ok(ciphertext.to_vec())
    }
}
```

**Day 12 — EncryptionConfig + feature flag**

```rust
// crates/mercury-crypto/src/config.rs

/// Configuration for selecting encryption backend.
/// In Phase 4, `Mls` variant will carry MLS group state.
#[derive(Debug, Clone)]
pub enum EncryptionConfig {
    Noop,
    // Mls { ... } — added in Phase 4
}

impl EncryptionConfig {
    pub fn build(&self) -> Box<dyn Encryptor> {
        match self {
            Self::Noop => Box::new(NoopEncryptor),
        }
    }
}
```

Tests:
- `NoopEncryptor` roundtrip: encrypt then decrypt returns original
- `NoopEncryptor` with empty input
- `NoopEncryptor` with large input (1MB — bounded test, NASA Rule #2)
- `EncryptionConfig::Noop.build()` returns working encryptor

---

### Days 13–16: Benchmarks (Step 1.4)

**Day 13 — Set up Criterion + MessageId / TimeBucket benchmarks**

```toml
# crates/mercury-core/Cargo.toml — add
[[bench]]
name = "core_benchmarks"
harness = false

[dev-dependencies]
criterion.workspace = true
```

```rust
// crates/mercury-core/benches/core_benchmarks.rs

use criterion::{black_box, criterion_group, criterion_main, Criterion};
use mercury_core::{MessageId, TimeBucket};

fn bench_message_id_generation(c: &mut Criterion) {
    c.bench_function("MessageId::new", |b| {
        b.iter(|| black_box(MessageId::new()));
    });
}

fn bench_time_bucket(c: &mut Criterion) {
    let ts = 1_700_000_000_000_u64; // fixed timestamp
    c.bench_function("TimeBucket::from_timestamp_ms", |b| {
        b.iter(|| black_box(TimeBucket::from_timestamp_ms(black_box(ts))));
    });
}

criterion_group!(benches, bench_message_id_generation, bench_time_bucket);
criterion_main!(benches);
```

**Day 14 — HLC + CRDT benchmarks**

```rust
// crates/mercury-crdt/benches/crdt_benchmarks.rs

fn bench_hlc_tick(c: &mut Criterion) { /* target: <50ns */ }
fn bench_hlc_merge(c: &mut Criterion) { /* target: <50ns */ }
fn bench_message_log_append_1000(c: &mut Criterion) { /* target: <1ms */ }
fn bench_orset_merge_1000(c: &mut Criterion) { /* target: <500µs */ }
```

**Day 15 — Cap'n Proto serialize/deserialize benchmarks**

```rust
// crates/mercury-core/benches/capnp_benchmarks.rs

fn bench_envelope_serialize(c: &mut Criterion) { /* target: <1µs */ }
fn bench_envelope_deserialize(c: &mut Criterion) { /* target: <1µs */ }
```

**Day 16 — Run all benchmarks, record baselines**

```bash
cargo bench --all-features 2>&1 | tee docs/phase-1-benchmarks.txt
```

Benchmark targets:

| Benchmark | Target | Crate |
|-----------|--------|-------|
| `MessageId::new` | <100ns | mercury-core |
| `TimeBucket::from_timestamp_ms` | <10ns | mercury-core |
| `Hlc::tick` | <50ns | mercury-crdt |
| `Hlc::merge` | <50ns | mercury-crdt |
| `MessageLog::append` (×1000) | <1ms | mercury-crdt |
| `ORSet::merge` (1000 elements) | <500µs | mercury-crdt |
| Cap'n Proto serialize (Envelope) | <1µs | mercury-core |
| Cap'n Proto deserialize (Envelope) | <1µs | mercury-core |

---

### Days 17–18: Property-Based Tests (CRDT Laws)

**Day 17 — Proptest strategies for all CRDTs**

```rust
// crates/mercury-crdt/tests/crdt_laws.rs

use proptest::prelude::*;
use mercury_crdt::*;

/// Generate arbitrary GCounter states for property testing.
fn arb_gcounter() -> impl Strategy<Value = GCounter> { /* ... */ }

/// CRDT Law 1: Commutativity — merge(a,b) == merge(b,a)
#[test]
fn gcounter_commutative() {
    proptest!(|(a in arb_gcounter(), b in arb_gcounter())| {
        let mut ab = a.clone(); ab.merge(&b);
        let mut ba = b.clone(); ba.merge(&a);
        prop_assert_eq!(ab, ba);
    });
}

/// CRDT Law 2: Associativity — merge(merge(a,b),c) == merge(a,merge(b,c))
#[test]
fn gcounter_associative() { /* ... */ }

/// CRDT Law 3: Idempotency — merge(a,a) == a
#[test]
fn gcounter_idempotent() { /* ... */ }
```

**Day 18 — Same laws for LwwRegister, ORSet, ReactionMap, MessageLog**

Each CRDT gets all 3 property tests. That's 5 CRDTs × 3 laws = 15 property tests.

---

### Days 19–20: ADRs + Documentation + Final Verification

**Day 19 — Write ADRs**

ADR-002: "Why ULID over UUIDv7 for MessageId"
- Context: Need sortable, unique message IDs generated client-side (offline-first)
- Decision: ULID — Crockford Base32 encoding (case-insensitive, URL-safe), 48-bit timestamp + 80-bit randomness, monotonic within same millisecond
- Trade-off: UUIDv7 is an IETF standard but has less ergonomic string representation

ADR-003: "Why custom CRDT over Automerge for message ordering"
- Context: Need conflict-free message ordering across offline devices
- Decision: Custom Rust CRDTs — smaller binary size (Automerge adds ~500KB WASM), we only need 5 specific CRDTs not a general-purpose document model, full control over merge semantics
- Trade-off: More code to maintain, but simpler and more predictable

**Day 20 — Documentation + final verification**

```bash
# Generate docs
cargo doc --no-deps --open

# Run full test suite
cargo test --all-features

# Run clippy
cargo clippy --all-targets --all-features -- -D warnings

# Run benchmarks
cargo bench --all-features

# Check coverage (requires cargo-llvm-cov)
cargo llvm-cov --all-features --html
# Open target/llvm-cov/html/index.html — verify >90% on mercury-core and mercury-crdt
```

---

## Deliverables Checklist

| # | Deliverable | Verify With |
|---|-------------|-------------|
| 1 | `mercury-core`: TenantId, MessageId, ChannelId, UserId, DeviceId | `cargo test -p mercury-core` |
| 2 | `mercury-core`: TimeBucket, TenantContext | `cargo test -p mercury-core` |
| 3 | `mercury-core`: Message, Channel, ContentType, validation | `cargo test -p mercury-core` |
| 4 | `mercury-core`: CoreError with thiserror | `cargo test -p mercury-core` |
| 5 | `mercury-crdt`: Hlc (tick, merge, Ord) | `cargo test -p mercury-crdt` |
| 6 | `mercury-crdt`: GCounter | `cargo test -p mercury-crdt` |
| 7 | `mercury-crdt`: LwwRegister | `cargo test -p mercury-crdt` |
| 8 | `mercury-crdt`: ORSet | `cargo test -p mercury-crdt` |
| 9 | `mercury-crdt`: ReactionMap | `cargo test -p mercury-crdt` |
| 10 | `mercury-crdt`: MessageLog (bounded, delta sync) | `cargo test -p mercury-crdt` |
| 11 | `mercury-crdt`: Mergeable trait + 15 property tests | `cargo test -p mercury-crdt` |
| 12 | `mercury-crypto`: Encryptor trait + NoopEncryptor | `cargo test -p mercury-crypto` |
| 13 | `mercury-crypto`: EncryptionConfig | `cargo test -p mercury-crypto` |
| 14 | Criterion benchmarks (8 benchmarks, all pass targets) | `cargo bench` |
| 15 | ADR-002: ULID over UUIDv7 | `cat docs/adr/002-ulid.md` |
| 16 | ADR-003: Custom CRDT over Automerge | `cat docs/adr/003-custom-crdt.md` |
| 17 | >90% test coverage on mercury-core + mercury-crdt | `cargo llvm-cov` |
| 18 | Clean `cargo doc` for all public APIs | `cargo doc --no-deps` |

---

## Dependency Graph (What Depends on What)

```
mercury-core (no internal deps)
    ↑
mercury-crdt (depends on mercury-core for UserId, MessageId, Bytes)
    ↑
mercury-crypto (no internal deps — standalone trait + stub)

mercury-nif (depends on mercury-core — but not touched in Phase 1)
mercury-db (not touched in Phase 1)
mercury-transport (not touched in Phase 1)
```

New workspace dependency to add:
- `ulid = { version = "1", features = ["serde"] }` — for MessageId

---

## Risk Mitigations

| Risk | Mitigation |
|------|-----------|
| ULID crate API changes | Pin exact version in Cargo.lock |
| Property tests too slow | Limit proptest cases to 256 (default), increase in CI nightly |
| Criterion benchmarks noisy on dev machine | Record baselines, compare relative not absolute |
| ORSet memory growth | Bounded by channel membership size (max 50,000 per architecture doc) |
| MessageLog unbounded growth | Hard cap at 100,000 entries (NASA Rule #2) |

---

## What's Next (Phase 2 Readiness)

After Phase 1, these crates are ready for Phase 2 integration:
- `mercury-core` types used in Elixir NIFs (via `mercury-nif`)
- `mercury-crdt::Hlc` used for message ordering in the gateway
- `mercury-crypto::NoopEncryptor` used for message encrypt/decrypt in dev
- All validation logic callable from Elixir via Rustler NIFs
