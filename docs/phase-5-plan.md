# Phase 5: Offline-First & CRDT Sync — Implementation Plan

## Goal
Enable full offline operation. Users can read, compose, and queue messages without
connectivity. When connection is restored, delta sync merges changes without conflicts
or data loss. After this phase, the server supports the complete sync protocol that
SDKs (Phase 6) will consume.

## Prerequisites
- Phase 4 complete (141 tests, all quality gates green)
- `mercury-crdt` crate has: HLC, GCounter, LWWRegister, ORSet, ReactionMap, MessageLog
  — all with `Mergeable` trait and property-based tests proving CRDT laws
- ScyllaDB stores messages with ULID-based `message_id` (sortable, embeds timestamp)
- Time-bucketed partitioning already in place (`bucket_id = epoch_days / 10`)
- NATS JetStream available for real-time event delivery
- HLC NIFs (`hlc_tick`, `hlc_merge`) already exposed to Elixir

## Scope Decisions

### In scope (server-side sync infrastructure)
- Delta sync protocol: server computes and serves deltas since a client's last HLC
- Sync channel events: clients request sync, server streams deltas
- Read position tracking: server-side read receipt storage + CRDT merge
- Multi-device fan-out: sync deltas pushed to all of a user's devices via NATS
- Offline queue drain: server accepts batched messages from reconnecting clients
- Serialization: CRDT deltas serialized via Cap'n Proto for wire efficiency

### Deferred to Phase 6 (SDK)
- Client-side SQLite/SQLCipher local storage
- Client-side offline queue persistence
- Client-side CRDT state management
- Platform-specific background sync (BGAppRefreshTask, WorkManager)

### Deferred to Phase 7 (Infrastructure)
- Tombstone garbage collection (30-day TTL cleanup job)
- Sync protocol compression (Brotli)
- Sync rate limiting per tenant

## Key Design Decision: Server as Sync Hub

The server is the authoritative merge point. Clients send deltas upstream, server
merges into ScyllaDB/PostgreSQL, then fans out merged state to other devices. This
avoids peer-to-peer CRDT gossip complexity while keeping the CRDT guarantees:

```
Device A (offline) ──→ queue locally ──→ reconnect ──→ send deltas to server
                                                              │
Server ──→ merge into DB ──→ compute outbound deltas ──→ fan out
                                                              │
Device B (online) ←──────────────────────────────────── receive deltas
Device C (offline) ←── (stored in NATS JetStream, delivered on reconnect)
```

---

## Steps

### 5.1 — Delta Sync Types in Rust (Days 1–3)

Define the delta types that flow between client and server. These go in
`mercury-crdt` since they're pure data + merge logic.

Deliverables in `crates/mercury-crdt/src/delta.rs`:

- `SyncRequest` struct:
  - `channel_id: [u8; 16]`
  - `last_hlc: Hlc` — client's last known clock for this channel
  - `device_id: [u8; 16]`

- `SyncResponse` struct:
  - `deltas: Vec<Delta>`
  - `server_hlc: Hlc` — server's current clock (client stores for next sync)
  - `has_more: bool` — pagination flag

- `Delta` enum (the unit of sync):
  ```rust
  pub enum Delta {
      MessageAppend {
          message_id: [u8; 16],
          sender_id: [u8; 16],
          encrypted_content: Vec<u8>,
          content_type: u8,
          hlc: Hlc,
      },
      MessageEdit {
          message_id: [u8; 16],
          encrypted_content: Vec<u8>,
          hlc: Hlc,
      },
      MessageDelete {
          message_id: [u8; 16],
          hlc: Hlc,
      },
      ReactionAdd {
          message_id: [u8; 16],
          user_id: [u8; 16],
          emoji: String,
          hlc: Hlc,
      },
      ReactionRemove {
          message_id: [u8; 16],
          user_id: [u8; 16],
          emoji: String,
          hlc: Hlc,
      },
      ReadPositionUpdate {
          channel_id: [u8; 16],
          user_id: [u8; 16],
          last_read_message_id: [u8; 16],
      },
  }
  ```

- `DeltaBatch` struct — bounded container for upstream deltas from client:
  - `deltas: Vec<Delta>` — max `MAX_DELTAS_PER_BATCH = 1000` (NASA Rule #2)
  - `device_hlc: Hlc` — client's clock at time of batch creation

- Serialization: `serde::{Serialize, Deserialize}` on all types. Cap'n Proto schema
  added in step 5.3 for wire format.

- `merge_delta(existing_state, delta) -> MergeResult` — applies a single delta using
  the appropriate CRDT merge rule:
  - `MessageAppend` → append to MessageLog (HLC-ordered, idempotent by message_id)
  - `MessageEdit` → LWWRegister merge (latest HLC wins)
  - `MessageDelete` → LWWRegister merge (delete wins if HLC newer than last edit)
  - `ReactionAdd/Remove` → ReactionMap (ORSet semantics, add wins on concurrent)
  - `ReadPositionUpdate` → GCounter-style max (never goes backward)

Tests:
- Delta serialization roundtrip
- merge_delta for each variant
- Idempotent: applying same delta twice = same result
- Ordering: out-of-order deltas produce same final state
- Batch bounds enforced

### 5.2 — Server-Side Sync Engine in Elixir (Days 3–7)

The sync engine computes deltas from ScyllaDB and serves them to clients.

Deliverables:

- `Persistence.Sync` module:
  - `get_deltas(tenant_id, channel_id, since_hlc, limit \\ 100) -> {:ok, [delta], server_hlc, has_more}`
    - Queries ScyllaDB `messages` table for rows after `since_hlc` timestamp
    - Converts message rows to `Delta.MessageAppend` structs
    - Queries `reactions` table for reactions on those messages
    - Queries `read_positions` for updated positions
    - Returns combined delta list, sorted by HLC
    - Bounded: max `limit` deltas per call (NASA Rule #2)

  - `apply_deltas(tenant_id, channel_id, deltas) -> :ok | {:error, reason}`
    - Receives upstream deltas from a reconnecting client
    - Writes new messages to ScyllaDB
    - Updates reactions in ScyllaDB
    - Updates read positions in ScyllaDB
    - Publishes each delta to NATS for fan-out to other devices
    - Bounded: max 1000 deltas per call

  - `get_sync_state(tenant_id, user_id) -> %{channel_id => last_hlc}`
    - Returns the last known HLC per channel for a user
    - Stored in PostgreSQL (new `sync_cursors` table)
    - Used on reconnect to determine what deltas to fetch

- `Persistence.Schema.SyncCursor` — Ecto schema:
  - `tenant_id`, `user_id`, `device_id`, `channel_id`, `last_hlc_wall`, `last_hlc_counter`, `last_hlc_node`
  - Composite primary key: `(tenant_id, user_id, device_id, channel_id)`
  - Updated after each successful sync

- PostgreSQL migration — add `sync_cursors` table to `pg-init.sql`:
  ```sql
  CREATE TABLE IF NOT EXISTS sync_cursors (
      tenant_id UUID NOT NULL,
      user_id UUID NOT NULL,
      device_id UUID NOT NULL,
      channel_id UUID NOT NULL,
      last_hlc_wall BIGINT NOT NULL DEFAULT 0,
      last_hlc_counter INT NOT NULL DEFAULT 0,
      last_hlc_node BYTEA NOT NULL DEFAULT '\x00',
      updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
      PRIMARY KEY (tenant_id, user_id, device_id, channel_id)
  );
  ```

### 5.3 — Sync Channel Events (Days 7–10)

New channel events in `MessageChannel` for the sync protocol.

Deliverables in `apps/gateway/lib/gateway/message_channel.ex`:

- `sync:request` — Client requests deltas since their last HLC
  - Payload: `{channel_id, last_hlc_wall, last_hlc_counter, last_hlc_node}`
  - Server calls `Persistence.Sync.get_deltas/4`
  - Replies with `{deltas: [...], server_hlc: {...}, has_more: bool}`
  - If `has_more`, client sends another `sync:request` with updated HLC

- `sync:push` — Client pushes offline-queued deltas to server
  - Payload: `{channel_id, deltas: [...], device_hlc: {...}}`
  - Server calls `Persistence.Sync.apply_deltas/3`
  - Server updates sync cursor for this device
  - Server publishes deltas to NATS for fan-out
  - Replies with `{accepted: count, server_hlc: {...}}`
  - Bounded: rejects if `length(deltas) > 1000`

- `sync:cursor` — Client reports its current sync position (heartbeat)
  - Payload: `{channel_id, last_hlc_wall, last_hlc_counter, last_hlc_node}`
  - Server updates `sync_cursors` table
  - No reply needed (fire-and-forget)

### 5.4 — Multi-Device Sync via NATS (Days 10–12)

When a delta is applied server-side, fan it out to all of the user's other devices.

Deliverables:

- NATS subject pattern: `mercury.{tenant_id}.sync.{user_id}`
  - Published by `Persistence.Sync.apply_deltas/3` after successful DB write
  - Each delta published as a separate NATS message (for granular delivery)

- `Gateway.SyncConsumer` — GenServer per connected user:
  - Subscribes to `mercury.{tenant_id}.sync.{user_id}` on connection
  - Receives deltas from NATS, pushes to all of the user's connected sockets
  - Filters out deltas that originated from the receiving device (no echo)
  - Unsubscribes on disconnect

- JetStream configuration:
  - Stream: `SYNC` with subject `mercury.*.sync.*`
  - Retention: 24 hours (covers typical offline gap)
  - Max messages per subject: 100,000 (NASA Rule #2)
  - Consumer: durable, per-device, deliver-on-reconnect

- Integration with existing `msg:send` flow:
  - When a message is sent via `msg:send`, also publish a `Delta.MessageAppend`
    to the sync NATS subject so offline devices pick it up on reconnect

### 5.5 — Read Position Tracking (Days 12–14)

Server-side read receipt management using GCounter (max) semantics.

Deliverables:

- `Persistence.ReadPositions` module:
  - `update(tenant_id, user_id, channel_id, message_id) -> :ok`
    - Writes to ScyllaDB `read_positions` table
    - Only advances forward (compares ULID, keeps max)
  - `get(tenant_id, user_id, channel_id) -> {:ok, message_id} | {:error, :not_found}`
  - `get_bulk(tenant_id, user_id, channel_ids) -> %{channel_id => message_id}`
    - Batch read for initial sync (all channels at once)

- New channel event `msg:read`:
  - Payload: `{message_id: hex}`
  - Server updates read position
  - Server broadcasts `msg:read` to channel (so other users see read receipts)
  - Also published as `Delta.ReadPositionUpdate` to sync subject

- ScyllaDB `read_positions` table already exists — just needs the Elixir module

### 5.6 — NIF Bridge: Delta Serialization (Days 14–15)

Expose delta serialization to Elixir so the gateway can encode/decode deltas
efficiently without JSON overhead.

New NIFs:
- `encode_delta(delta_map) -> {:ok, binary}` — Elixir map → binary (Cap'n Proto or serde bincode)
- `decode_delta(binary) -> {:ok, delta_map}` — binary → Elixir map
- `encode_sync_response(deltas, server_hlc, has_more) -> {:ok, binary}`
- `decode_sync_request(binary) -> {:ok, map}`

Alternative: If Cap'n Proto schema isn't ready, use JSON for now and optimize
in Phase 7. The sync protocol works the same either way — only the wire encoding
changes. **Decision: use JSON initially, add binary encoding as optimization later.**
This avoids blocking on Cap'n Proto tooling and keeps the phase focused on correctness.

With JSON, no new NIFs are needed for delta serialization — Elixir's `Jason` handles
it. The existing HLC NIFs (`hlc_tick`, `hlc_merge`) are sufficient.

### 5.7 — Integration Tests (Days 15–17)

Test scenarios (Elixir, integration, require Docker):

1. **Delta sync roundtrip**: Send 10 messages → request sync with HLC=0 → get all 10 back as deltas
2. **Incremental sync**: Send 5 messages → sync → send 5 more → sync again → get only the new 5
3. **Pagination**: Send 200 messages → sync with limit=50 → verify `has_more=true` → paginate through all
4. **Offline push**: Simulate offline client pushing 20 queued messages → verify all persisted in ScyllaDB
5. **Multi-device fan-out**: Device A sends message → Device B (same user) receives delta via NATS
6. **Read position**: Update read position → verify it advances → verify it never goes backward
7. **Sync cursor persistence**: Sync → disconnect → reconnect → sync resumes from cursor
8. **Bounded batch**: Push >1000 deltas → verify rejection

Test scenarios (Rust, unit):

9. **Delta merge idempotency**: Apply same delta twice → same state
10. **Delta ordering**: Apply deltas out of order → same final state as in-order
11. **DeltaBatch bounds**: Exceed MAX_DELTAS_PER_BATCH → error

### 5.8 — ADR (Day 17)
- ADR-008: "Delta sync protocol design and CRDT merge rules"

---

## File Inventory (New/Modified)

### New Files
```
crates/mercury-crdt/src/delta.rs                        — Delta types + merge logic
apps/persistence/lib/persistence/sync.ex                — Server-side sync engine
apps/persistence/lib/persistence/read_positions.ex      — Read position CRUD
apps/persistence/lib/persistence/schema/sync_cursor.ex  — SyncCursor Ecto schema
apps/gateway/lib/gateway/sync_consumer.ex               — NATS sync fan-out GenServer
docs/adr/008-delta-sync-protocol.md
```

### Modified Files
```
crates/mercury-crdt/src/lib.rs                          — pub mod delta
crates/mercury-crdt/Cargo.toml                          — add serde
apps/gateway/lib/gateway/message_channel.ex             — sync:request, sync:push, sync:cursor, msg:read events
apps/gateway/lib/gateway/application.ex                 — add SyncConsumer to supervision tree
infra/docker/pg-init.sql                                — add sync_cursors table
infra/docker/scylla-init.cql                            — (no changes, tables exist)
apps/persistence/test/persistence_integration_test.exs  — sync + read position integration tests
```

---

## Acceptance Criteria

| # | Criterion | Verification |
|---|-----------|-------------|
| 1 | Delta types serialize/deserialize correctly | Rust unit test |
| 2 | merge_delta is idempotent for all variants | Rust property test |
| 3 | Out-of-order deltas produce same final state | Rust unit test |
| 4 | Sync returns correct deltas after a given HLC | Elixir integration test |
| 5 | Pagination works (has_more flag, continuation) | Elixir integration test |
| 6 | Offline push: queued deltas accepted and persisted | Elixir integration test |
| 7 | Multi-device: delta published to NATS, received by other device | Elixir integration test |
| 8 | Read position never goes backward | Elixir integration test |
| 9 | Sync cursor persists across reconnects | Elixir integration test |
| 10 | Batch size bounded at 1000 deltas | Elixir unit test |
| 11 | ADR-008 written | File exists |
| 12 | All existing tests still pass (141+) | Full quality gate |

## Quality Gates (same as previous phases)
- Rust: clippy zero warnings, fmt clean, all tests pass
- Elixir: dialyzer zero warnings, credo strict zero issues, format clean, all tests pass
- Integration tests pass with Docker running

---

## Timeline Estimate
- Days 1–3: Delta types + merge logic + Rust tests
- Days 3–7: Server-side sync engine (Persistence.Sync + SyncCursor)
- Days 7–10: Sync channel events
- Days 10–12: Multi-device NATS fan-out
- Days 12–14: Read position tracking
- Days 14–15: Wire format decision (JSON for now)
- Days 15–17: Integration tests + ADR

Total: ~17 working days
