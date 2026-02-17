# ADR-008: Delta Sync Protocol Design and CRDT Merge Rules

## Status: Accepted

## Context
Mercury needs offline-first support: users compose messages without connectivity,
and changes sync automatically on reconnect. The sync protocol must be efficient
(delta-only, not full state), conflict-free (no manual merge), and bounded
(no unbounded resource consumption).

We already have CRDT primitives (HLC, GCounter, LWWRegister, ORSet, MessageLog,
ReactionMap) from Phase 1 with property-based tests proving commutativity,
associativity, and idempotency.

## Decision

### Server as Sync Hub
The server is the authoritative merge point. Clients push deltas upstream, the
server merges into ScyllaDB/PostgreSQL, then fans out to other devices via NATS.
This avoids peer-to-peer CRDT gossip complexity.

### Delta Types
A `Delta` is the atomic unit of sync — one change that can be applied idempotently:
- `MessageAppend` — new message (HLC-ordered, idempotent by message_id)
- `MessageEdit` — LWWRegister merge (latest HLC wins)
- `MessageDelete` — LWWRegister merge (delete wins if HLC newer)
- `ReactionAdd/Remove` — ORSet semantics (add wins on concurrent add+remove)
- `ReadPositionUpdate` — GCounter max (never goes backward)

### Sync Protocol
1. Client reconnects, sends `sync:request` with last known HLC per channel
2. Server queries ScyllaDB for messages after that HLC, returns deltas
3. Client sends `sync:push` with offline-queued deltas
4. Server merges, fans out to other devices via NATS JetStream

### Bounds (NASA Rule #2)
- Max 1000 deltas per push batch
- Max 100 deltas per sync response (paginated via `has_more` flag)
- NATS JetStream retains 24h of sync messages per user
- Sync cursors tracked per device in PostgreSQL

### Wire Format
JSON initially (via Jason). Binary encoding (Cap'n Proto) deferred to Phase 7
as an optimization. The protocol is format-agnostic — only the encoding changes.

## Consequences

### Easier
- Offline compose works — messages queued locally, pushed on reconnect
- Multi-device sync — NATS delivers deltas to all connected devices
- No data loss — CRDT merge is mathematically conflict-free
- Incremental sync — only changes transferred, not full state

### Harder
- Server must handle delta ordering across time buckets
- Sync cursors add PostgreSQL state per device per channel
- NATS JetStream adds operational complexity
- JSON wire format is larger than binary (acceptable for now)
