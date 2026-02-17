# Phase 3: Persistence Layer — Implementation Plan

## Goal
Messages survive restarts. Wire ScyllaDB (messages), PostgreSQL (users/tenants),
Dragonfly (cache), and NATS (event bus) into the existing gateway. After this
phase, the full write path works: client → gateway → validate → persist → fan-out.

## Prerequisites
- Phase 2 complete (101 tests, all quality gates green)
- `docker compose up -d` starts ScyllaDB, PostgreSQL/Citus, NATS, Dragonfly, Redpanda
- `mercury-db` crate exists as stub

## Scope Decisions
- **In scope**: ScyllaDB messages, PostgreSQL users/tenants/channels, Dragonfly cache,
  NATS JetStream events, gateway↔persistence integration, message history API
- **Deferred to Phase 7**: File uploads/media pipeline (needs object storage),
  identity verification/anti-spam (needs email/SMS provider), GDPR/abuse tables
  (needs admin dashboard). Schemas are created now but service code is deferred.
- **Citus sharding**: DDL uses plain PostgreSQL (no `create_distributed_table`).
  Citus extension added in Phase 7 when deploying to multi-node. Schemas are
  Citus-ready (composite PKs with `tenant_id` first).

---

## Steps

### 3.1 — Docker Dev Environment (Day 1)
Verify all services start and are reachable.

Deliverables:
- `make dev` starts all 5 containers, waits for health checks
- `infra/docker/pg-init.sql` creates the `mercury_dev` database with extensions
- `infra/docker/scylla-init.cql` creates keyspace + tables
- Makefile target `db-reset` drops and recreates all schemas

Verification:
```
make dev
cqlsh localhost -e "SELECT * FROM system_schema.keyspaces WHERE keyspace_name='mercury'"
psql -h localhost -U mercury -d mercury_dev -c "SELECT 1"
```

### 3.2 — ScyllaDB Schema + Rust Client (Days 2–4)
Implement `mercury-db` ScyllaDB client with the message tables.

Deliverables:
- `infra/docker/scylla-init.cql`: 4 tables (messages, read_positions, channel_members, reactions)
- `crates/mercury-db/src/scylla.rs`:
  - `ScyllaPool` — bounded connection pool via `scylla` crate
  - `insert_message(msg) -> Result<()>` — prepared statement write
  - `get_messages(tenant, channel, bucket, limit) -> Result<Vec<Message>>` — paginated read
  - `get_recent_messages(tenant, channel, limit) -> Result<Vec<Message>>` — reads current + previous bucket
  - `insert_read_position` / `get_read_position`
  - All queries use prepared statements (created at pool init)
  - Retry: 3 attempts, exponential backoff (100ms, 200ms, 400ms)
- Add to `Cargo.toml`: `scylla = "0.15"`, `uuid = "1"`

Tests (require running ScyllaDB — tagged `#[cfg(feature = "integration")]`):
- Write message → read back → verify fields
- Time-bucket boundary: messages in different buckets returned correctly
- Pagination: insert 100 messages, read 20 at a time
- Tenant isolation: tenant A's messages not visible to tenant B

Benchmark:
- `insert_message` target: <1ms P99 (local ScyllaDB)
- `get_messages(50)` target: <2ms P99

### 3.3 — PostgreSQL Schema + Rust Client (Days 4–6)
Core user/tenant tables and the sqlx client.

Deliverables:
- `infra/docker/pg-init.sql`: Core tables — tenants, users, devices, channels
  (Citus-ready composite PKs but no `create_distributed_table` yet)
- `crates/mercury-db/src/postgres.rs`:
  - `PgPool` — sqlx connection pool
  - `create_tenant(name, plan) -> Result<Tenant>`
  - `get_tenant(tenant_id) -> Result<Option<Tenant>>`
  - `create_user(tenant_id, display_name) -> Result<User>`
  - `get_user(tenant_id, user_id) -> Result<Option<User>>`
  - `create_channel(tenant_id, channel_type, name, created_by) -> Result<Channel>`
  - `get_channel(tenant_id, channel_id) -> Result<Option<Channel>>`
  - `add_channel_member` / `remove_channel_member` / `get_channel_members`
- Add to `Cargo.toml`: `sqlx = { version = "0.8", features = ["runtime-tokio", "postgres", "uuid", "chrono"] }`
- `sqlx migrate` directory at `crates/mercury-db/migrations/` with numbered SQL files

Tests (require running PostgreSQL — tagged `#[cfg(feature = "integration")]`):
- CRUD roundtrip for tenant, user, channel
- Tenant isolation: user from tenant A not visible via tenant B query
- Channel membership: add/remove/list members

### 3.4 — Dragonfly Cache Client (Day 7)
Redis-protocol cache layer.

Deliverables:
- `crates/mercury-db/src/cache.rs`:
  - `CachePool` — `redis` crate connection pool to Dragonfly
  - `cache_user(tenant, user) -> Result<()>` — SET with 5min TTL
  - `get_cached_user(tenant, user_id) -> Result<Option<User>>` — GET
  - `cache_channel_members(tenant, channel, members) -> Result<()>` — SADD with 1min TTL
  - `invalidate_user(tenant, user_id) -> Result<()>` — DEL
- Add to `Cargo.toml`: `redis = { version = "0.27", features = ["tokio-comp"] }`
- Cache-aside pattern: check cache → miss → query DB → populate cache

Tests:
- Set/get roundtrip
- TTL expiry
- Invalidation

### 3.5 — NATS JetStream Client (Days 8–9)
Event bus for message persistence pipeline.

Deliverables:
- `crates/mercury-db/src/nats.rs`:
  - `NatsClient` — `async-nats` JetStream client
  - `publish_message_event(tenant, channel, msg) -> Result<()>`
  - `subscribe_messages(tenant, channel) -> Result<Subscriber>`
  - Stream config: `mercury-messages` stream, subjects `mercury.*.messages.*`, 24h retention
- Add to `Cargo.toml`: `async-nats = "0.38"`

Tests:
- Publish → subscribe → receive roundtrip
- Message ordering preserved

### 3.6 — NIF Bridge: Persistence Functions (Days 9–10)
Expose DB operations to Elixir via new NIFs.

New NIFs in `mercury-nif`:
- `db_write_message(pool_ref, tenant, channel, bucket, msg_id, sender, content, content_type) -> :ok | {:error, reason}`
- `db_read_messages(pool_ref, tenant, channel, limit) -> {:ok, [message]} | {:error, reason}`
- `db_create_tenant(pool_ref, name, plan) -> {:ok, tenant_id} | {:error, reason}`
- `db_get_tenant(pool_ref, tenant_id) -> {:ok, tenant} | {:error, :not_found}`

All DB NIFs run on `DirtyCpu` scheduler (they block on I/O).

Alternative approach (simpler, preferred): Use Elixir-native clients instead of
NIFs for database access. NIFs add complexity for I/O-bound work where BEAM
excels. Decision:
- **ScyllaDB**: Use `xandra` (Elixir CQL driver) — mature, async, connection pooling
- **PostgreSQL**: Use `ecto` + `postgrex` — standard Elixir stack
- **Dragonfly**: Use `redix` — lightweight Redis client
- **NATS**: Use `gnat` — Elixir NATS client

This avoids NIF complexity for I/O and keeps Rust NIFs for CPU-bound work only
(validation, crypto, CRDT). Write ADR-005 explaining this decision.

### 3.7 — Elixir Database Layer (Days 10–14)
Elixir clients for all datastores.

Deliverables:
- New umbrella app: `apps/persistence/`
  - `Persistence.Repo` — Ecto repo for PostgreSQL
  - `Persistence.Scylla` — Xandra pool + prepared queries for ScyllaDB
  - `Persistence.Cache` — Redix pool for Dragonfly
  - `Persistence.Events` — Gnat client for NATS JetStream
- Ecto schemas (PostgreSQL):
  - `Persistence.Schema.Tenant`
  - `Persistence.Schema.User`
  - `Persistence.Schema.Device`
  - `Persistence.Schema.Channel`
  - `Persistence.Schema.ChannelMember`
- Ecto migrations matching the SQL from architecture.md (core tables only)
- ScyllaDB query modules:
  - `Persistence.Messages.write(tenant, channel, msg) -> :ok`
  - `Persistence.Messages.read(tenant, channel, opts) -> {:ok, [msg]}`
  - `Persistence.Messages.read_positions/update_read_position`
- Supervision tree: Repo, Xandra pool, Redix pool, Gnat connection

### 3.8 — Gateway ↔ Persistence Integration (Days 14–17)
Wire the message flow end-to-end.

Updated `MessageChannel.handle_in("msg:send")`:
1. Rate limit check (existing)
2. NIF validate (existing)
3. NIF encrypt (existing)
4. **NEW**: `Persistence.Messages.write(tenant, channel, msg)` — write to ScyllaDB
5. Broadcast to PubSub (existing)
6. **NEW**: `Persistence.Events.publish(tenant, channel, msg)` — publish to NATS

New channel event `msg:history`:
- Client requests: `{"before": message_id, "limit": 50}`
- Server reads from ScyllaDB via `Persistence.Messages.read`
- Returns paginated message list

New `Persistence.Consumer` GenServer:
- Subscribes to NATS `mercury.*.messages.*`
- Writes to Redpanda audit topic (fire-and-forget)
- This is the `FanoutWorker` from Phase 2, now with real persistence

### 3.9 — Redpanda Audit Log (Day 17–18)
Durable event log for compliance.

Deliverables:
- `Persistence.Audit` — `brod` or `kafka_ex` client writing to Redpanda
- Topics: `mercury.audit.messages`, `mercury.audit.auth`
- Consumer in `Persistence.Consumer` writes every message event to audit topic
- Retention: 90 days (configured in Redpanda)

### 3.10 — Integration Tests (Days 18–20)
End-to-end tests with real databases.

Test scenarios:
1. Send message via WebSocket → verify in ScyllaDB → verify in Redpanda audit log
2. Send message → disconnect → reconnect → request history → get message back
3. Tenant A sends message → tenant B queries same channel_id → gets nothing
4. Write 1000 messages → read with pagination → all returned in order
5. Time-bucket boundary: messages spanning 2 buckets returned correctly
6. Cache: first read populates cache, second read hits cache (verify with Dragonfly MONITOR)

### 3.11 — ADRs (Day 20)
- ADR-005: "Why Elixir-native DB clients over Rust NIFs for I/O"
- ADR-006: "Why NATS + Redpanda over Kafka alone"

---

## Dependencies (Elixir)

Add to `apps/persistence/mix.exs`:
```elixir
{:ecto_sql, "~> 3.12"},
{:postgrex, "~> 0.19"},
{:xandra, "~> 0.19"},
{:redix, "~> 1.5"},
{:gnat, "~> 1.8"},
{:brod, "~> 4.0"},       # Kafka/Redpanda client
{:jason, "~> 1.4"}
```

## Dependencies (Rust — mercury-db, for benchmarks/integration tests only)
```toml
scylla = "0.15"
sqlx = { version = "0.8", features = ["runtime-tokio", "postgres", "uuid", "chrono"] }
redis = { version = "0.27", features = ["tokio-comp"] }
async-nats = "0.38"
```

---

## File Inventory (New/Modified)

### New Files
```
apps/persistence/mix.exs
apps/persistence/lib/persistence/application.ex
apps/persistence/lib/persistence/repo.ex              — Ecto Repo
apps/persistence/lib/persistence/scylla.ex             — Xandra pool + queries
apps/persistence/lib/persistence/cache.ex              — Redix pool
apps/persistence/lib/persistence/events.ex             — Gnat NATS client
apps/persistence/lib/persistence/audit.ex              — Redpanda writer
apps/persistence/lib/persistence/consumer.ex           — NATS consumer GenServer
apps/persistence/lib/persistence/messages.ex           — ScyllaDB message queries
apps/persistence/lib/persistence/schema/tenant.ex
apps/persistence/lib/persistence/schema/user.ex
apps/persistence/lib/persistence/schema/device.ex
apps/persistence/lib/persistence/schema/channel.ex
apps/persistence/lib/persistence/schema/channel_member.ex
apps/persistence/priv/repo/migrations/001_create_tenants.exs
apps/persistence/priv/repo/migrations/002_create_users.exs
apps/persistence/priv/repo/migrations/003_create_devices.exs
apps/persistence/priv/repo/migrations/004_create_channels.exs
apps/persistence/priv/repo/migrations/005_create_channel_members.exs
apps/persistence/test/persistence_messages_test.exs
apps/persistence/test/persistence_repo_test.exs
apps/persistence/test/persistence_integration_test.exs

infra/docker/pg-init.sql                               — PostgreSQL init (extensions)
infra/docker/scylla-init.cql                           — ScyllaDB keyspace + tables

docs/adr/005-elixir-db-clients.md
docs/adr/006-nats-redpanda.md
```

### Modified Files
```
apps/gateway/lib/gateway/message_channel.ex            — Add persistence + NATS publish
apps/gateway/mix.exs                                   — Add persistence dep
apps/fanout/lib/fanout/worker.ex                       — Wire to real NATS consumer
docker-compose.yml                                     — Add init scripts volume mounts
Makefile                                               — Add db-reset, db-migrate targets
Cargo.toml                                             — Add new workspace deps
crates/mercury-db/Cargo.toml                           — Add scylla, sqlx, redis, async-nats
crates/mercury-db/src/lib.rs                           — Module declarations
```

---

## Acceptance Criteria

| # | Criterion | Verification |
|---|-----------|-------------|
| 1 | Messages survive full restart | Integration test: write → `docker compose restart` → read back |
| 2 | ScyllaDB write P99 <5ms | Benchmark with 1K writes |
| 3 | PostgreSQL user lookup P99 <2ms | Benchmark with 1K reads |
| 4 | Dragonfly cache hit rate >95% | Integration test with cache stats |
| 5 | NATS delivery P99 <1ms | Benchmark publish→subscribe |
| 6 | Time-bucket rollover correct | Unit test at day boundary |
| 7 | Tenant isolation verified | Integration test: cross-tenant query returns empty |
| 8 | End-to-end: send → ScyllaDB + Redpanda + delivered | Integration test |
| 9 | ADR-005 + ADR-006 written | File exists |
| 10 | All existing tests still pass (101+) | `make test` |

## Quality Gates (same as Phase 2)
- Rust: clippy zero warnings, fmt clean, all tests pass
- Elixir: dialyzer zero warnings, credo strict zero issues, format clean, all tests pass
- Integration tests pass with `make dev` running

---

## Timeline Estimate
- Days 1–6: Infrastructure + Rust DB clients (ScyllaDB + PostgreSQL)
- Days 7–9: Cache + NATS clients
- Days 10–14: Elixir persistence app + Ecto schemas
- Days 14–17: Gateway integration
- Days 17–20: Audit log + integration tests + ADRs

Total: ~20 working days
