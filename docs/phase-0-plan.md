# Phase 0: Foundation & Toolchain — Implementation Plan

**Timeline:** Weeks 1–3 (15 working days)
**Goal:** Every subsequent phase can start with `make dev && make test` and get a green build.

---

## Day-by-Day Breakdown

### Days 1–3: Monorepo Skeleton (Step 0.1)

**Day 1 — Repository & Rust Workspace**

```bash
# Initialize git repo
git init mercury && cd mercury
echo "# Mercury Messaging" > README.md
git add . && git commit -m "initial commit"

# Create Rust workspace
cat > Cargo.toml << 'EOF'
[workspace]
resolver = "2"
members = [
    "crates/mercury-core",
    "crates/mercury-crypto",
    "crates/mercury-crdt",
    "crates/mercury-db",
    "crates/mercury-nif",
    "crates/mercury-transport",
]

[workspace.package]
version = "0.1.0"
edition = "2024"
license = "AGPL-3.0"
rust-version = "1.85"

[workspace.dependencies]
anyhow = "1"
bytes = "1"
thiserror = "2"
tokio = { version = "1", features = ["full"] }
tracing = "0.1"
tracing-subscriber = { version = "0.3", features = ["env-filter", "json"] }
serde = { version = "1", features = ["derive"] }
uuid = { version = "1", features = ["v4", "v7", "serde"] }
capnp = "0.20"
criterion = { version = "0.5", features = ["html_reports"] }
proptest = "1"

[workspace.lints.rust]
warnings = "deny"
unsafe_op_in_unsafe_fn = "deny"

[workspace.lints.clippy]
all = "warn"
pedantic = "warn"
EOF
```

Create each crate skeleton:

```bash
for crate in mercury-core mercury-crypto mercury-crdt mercury-db mercury-nif mercury-transport; do
    cargo init --lib "crates/$crate"
done
```

Each crate's `Cargo.toml` inherits workspace settings:

```toml
# crates/mercury-core/Cargo.toml
[package]
name = "mercury-core"
version.workspace = true
edition.workspace = true

[dependencies]
anyhow.workspace = true
bytes.workspace = true
thiserror.workspace = true
uuid.workspace = true
serde.workspace = true

[dev-dependencies]
proptest.workspace = true

[lints]
workspace = true
```

Each crate's `lib.rs` starts with the NASA/Tiger Style header:

```rust
// crates/mercury-core/src/lib.rs
#![doc = "Mercury core domain types, validation, and shared logic."]

pub fn hello() -> &'static str {
    "mercury-core"
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn it_works() {
        assert_eq!(hello(), "mercury-core");
    }
}
```

Verify: `cargo check && cargo test` — all green.

**Day 2 — Elixir Umbrella**

```bash
# Install Elixir toolchain (if not present)
# mix local.hex --force && mix local.rebar --force

# Create umbrella project at repo root
mix new mercury_umbrella --umbrella --app mercury
# This creates mix.exs at root + apps/ directory

# Create OTP apps
cd apps
mix new gateway --sup
mix new presence --sup
mix new fanout --sup
cd ..
```

Root `mix.exs` config:

```elixir
# mix.exs (umbrella root)
defmodule Mercury.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit],
        flags: [:error_handling, :underspecs, :unmatched_returns]
      ]
    ]
  end

  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: :test}
    ]
  end
end
```

Verify: `mix deps.get && mix compile && mix test` — all green.

**Day 3 — Directory Structure & Scaffolding**

Create remaining directories:

```bash
# Client placeholders are not needed — Mercury is an SDK, not an app.
# SDK crates live in sdks/ and are created in Phase 6.
mkdir -p sdks
touch sdks/.gitkeep

# Infrastructure
mkdir -p infra/{k8s,terraform,docker}
touch infra/{k8s,terraform,docker}/.gitkeep

# Tests
mkdir -p tests/{integration,load,chaos}
touch tests/{integration,load,chaos}/.gitkeep

# Docs
mkdir -p docs/{adr,runbooks}
cp architecture.md docs/architecture.md  # or symlink

# Cap'n Proto schemas (placeholder)
mkdir -p schema/mercury/v1
touch schema/capnpc.toml
```

Create `.gitignore`:

```gitignore
# Rust
/target/
**/*.rs.bk

# Elixir
/_build/
/deps/
*.ez
*.beam
/cover/

# OS
.DS_Store
*.swp

# IDE
.idea/
.vscode/
*.iml

# Environment
.env
.env.local
```

Write ADR-001:

```bash
cat > docs/adr/001-monorepo.md << 'EOF'
# ADR-001: Monorepo over Polyrepo

## Status: Accepted

## Context
Mercury has Rust crates, Elixir apps, Cap'n Proto schemas, client code, and
infrastructure config. We need to decide whether to use a single repository
or multiple repositories.

## Decision
Use a monorepo. All code lives in one repository.

## Consequences
- **Easier:** Atomic commits across Rust + Elixir + schemas. Single CI pipeline.
  Shared tooling. No version matrix between repos.
- **Harder:** Larger repo size over time. CI must be smart about what to rebuild
  (path-based triggers). Need clear directory boundaries to avoid coupling.
EOF
```

Verify: `git add -A && git status` shows clean structure.

---

### Days 4–7: Cap'n Proto Schemas (Step 0.2)

**Day 4 — Install capnp toolchain & create message.capnp + envelope.capnp**

```bash
# macOS
brew install capnp
```

```capnp
# schema/mercury/v1/envelope.capnp
@0xb7c5f0e1a2d3f4e5;

struct Envelope {
  # Outer wire format — routing info only, no plaintext content.
  # Server reads this to route; inner payload is E2EE.
  tenantId  @0 :Data;       # 16 bytes UUID
  channelId @1 :Data;       # 16 bytes UUID
  senderId  @2 :Data;       # 16 bytes UUID (cleared by sealed sender)
  messageId @3 :Data;       # 16 bytes ULID
  timestamp @4 :UInt64;     # Unix millis
  payload   @5 :Data;       # Encrypted MLS ciphertext (opaque to server)
}
```

```capnp
# schema/mercury/v1/message.capnp
@0xa1b2c3d4e5f6a7b8;

using Envelope = import "envelope.capnp";

enum ContentType {
  text     @0;
  image    @1;
  file     @2;
  reaction @3;
  edit     @4;
  delete   @5;
}

struct MessageMetadata {
  contentType @0 :ContentType;
  replyTo     @1 :Data;          # Optional ULID of parent message
  editOf      @2 :Data;          # Optional ULID of original (for edits)
}

struct FileAttachment {
  fileId        @0 :Text;
  encryptedUrl  @1 :Text;
  encryptionKey @2 :Data;        # Per-file AES-256-GCM key (encrypted with MLS group key)
  encryptionIv  @3 :Data;
  mimeType      @4 :Text;
  sizeBytes     @5 :UInt64;
  thumbnail     @6 :Thumbnail;
}

struct Thumbnail {
  url    @0 :Text;
  width  @1 :UInt32;
  height @2 :UInt32;
}

struct Reaction {
  targetMessageId @0 :Data;      # ULID of message being reacted to
  emoji           @1 :Text;      # Unicode emoji or custom ID
  remove          @2 :Bool;      # true = remove reaction, false = add
}

struct MessagePayload {
  # Decrypted inner content (only visible to clients, never to server)
  metadata    @0 :MessageMetadata;
  union {
    text       @1 :Text;
    file       @2 :FileAttachment;
    reaction   @3 :Reaction;
    edit       @4 :Text;         # New content for edited message
    delete     @5 :Void;         # Tombstone
  }
}
```

**Day 5 — channel.capnp + user.capnp**

```capnp
# schema/mercury/v1/channel.capnp
@0xc1d2e3f4a5b6c7d8;

enum ChannelType {
  dm        @0;
  group     @1;
  broadcast @2;
}

struct Channel {
  tenantId    @0 :Data;          # 16 bytes UUID
  channelId   @1 :Data;          # 16 bytes UUID
  channelType @2 :ChannelType;
  name        @3 :Text;          # Optional, for groups/broadcasts
  createdBy   @4 :Data;          # 16 bytes UUID
  createdAt   @5 :UInt64;        # Unix millis
}

struct ChannelMember {
  tenantId  @0 :Data;
  channelId @1 :Data;
  userId    @2 :Data;
  role      @3 :UInt8;           # 0=member, 1=admin, 2=owner
  joinedAt  @4 :UInt64;
}
```

```capnp
# schema/mercury/v1/user.capnp
@0xd1e2f3a4b5c6d7e8;

struct User {
  tenantId    @0 :Data;          # 16 bytes UUID
  userId      @1 :Data;          # 16 bytes UUID
  displayName @2 :Text;
  avatarUrl   @3 :Text;
  role        @4 :UInt8;         # 0=user, 1=moderator, 2=admin, 3=owner
  createdAt   @5 :UInt64;
}

struct Device {
  tenantId      @0 :Data;
  deviceId      @1 :Data;
  userId        @2 :Data;
  deviceName    @3 :Text;
  platform      @4 :Text;       # "ios", "android", "web", "desktop"
  pushToken     @5 :Text;       # APNs/FCM token
  mlsKeyPackage @6 :Data;       # MLS KeyPackage bytes
  lastSeenAt    @7 :UInt64;
}

struct AuthToken {
  tenantId  @0 :Data;
  userId    @1 :Data;
  deviceId  @2 :Data;
  expiresAt @3 :UInt64;
  scopes    @4 :List(Text);
}
```

**Day 6 — sync.capnp**

```capnp
# schema/mercury/v1/sync.capnp
@0xe1f2a3b4c5d6e7f8;

struct HybridLogicalClock {
  wallClockMs @0 :UInt64;        # Physical wall clock (Unix millis)
  counter     @1 :UInt32;        # Logical counter for same-ms events
  nodeId      @2 :Data;          # 16 bytes — unique node identifier
}

struct SyncRequest {
  tenantId     @0 :Data;
  channelId    @1 :Data;
  deviceId     @2 :Data;
  lastKnownHlc @3 :HybridLogicalClock;
  maxDeltas    @4 :UInt32;       # Bounded: max 10,000 (NASA Rule #2)
}

struct SyncResponse {
  deltas            @0 :List(CRDTDelta);
  newHlc            @1 :HybridLogicalClock;
  hasMore           @2 :Bool;    # Pagination: more deltas available
  continuationToken @3 :Data;    # Opaque token for next page
}

struct CRDTDelta {
  hlc @0 :HybridLogicalClock;   # When this delta was created
  union {
    messageAppend      @1 :Data; # Encrypted message bytes
    messageEdit        @2 :Data; # Encrypted edit payload
    messageDelete      @3 :Data; # ULID of deleted message
    reactionAdd        @4 :ReactionDelta;
    reactionRemove     @5 :ReactionDelta;
    memberAdd          @6 :MemberDelta;
    memberRemove       @7 :MemberDelta;
    readPositionUpdate @8 :ReadPositionDelta;
  }
}

struct ReactionDelta {
  messageId @0 :Data;            # ULID of target message
  userId    @1 :Data;
  emoji     @2 :Text;
}

struct MemberDelta {
  channelId @0 :Data;
  userId    @1 :Data;
  role      @2 :UInt8;
}

struct ReadPositionDelta {
  channelId        @0 :Data;
  userId           @1 :Data;
  lastReadMessageId @2 :Data;   # ULID
}
```

**Day 7 — Schema compilation & Rust/Elixir codegen**

Create the build script:

```bash
# schema/capnpc.toml
# Cap'n Proto compiler configuration

# Verify all schemas compile
capnp compile -o- schema/mercury/v1/*.capnp
```

Add `capnpc` to Rust build:

```toml
# crates/mercury-core/Cargo.toml (add)
[build-dependencies]
capnpc = "0.20"
```

```rust
// crates/mercury-core/build.rs
fn main() {
    capnpc::CompilerCommand::new()
        .src_prefix("../../schema")
        .file("../../schema/mercury/v1/envelope.capnp")
        .file("../../schema/mercury/v1/message.capnp")
        .file("../../schema/mercury/v1/channel.capnp")
        .file("../../schema/mercury/v1/user.capnp")
        .file("../../schema/mercury/v1/sync.capnp")
        .run()
        .expect("capnp compile failed");
}
```

Verify: `cargo build` generates Rust code from schemas. `capnp compile` passes on all `.capnp` files.

---

### Days 8–11: CI/CD Pipeline (Step 0.3)

**Day 8 — GitHub Actions: Rust CI**

```yaml
# .github/workflows/rust.yml
name: Rust CI

on:
  push:
    branches: [main]
    paths: ["crates/**", "schema/**", "Cargo.toml", "Cargo.lock"]
  pull_request:
    paths: ["crates/**", "schema/**", "Cargo.toml", "Cargo.lock"]

env:
  CARGO_TERM_COLOR: always
  RUSTFLAGS: "-D warnings"

jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: dtolnay/rust-toolchain@stable
        with:
          components: clippy, rustfmt
      - uses: Swatinem/rust-cache@v2

      - name: Install Cap'n Proto
        run: sudo apt-get install -y capnproto

      - name: Format check
        run: cargo fmt --all -- --check

      - name: Clippy
        run: cargo clippy --all-targets --all-features -- -D warnings

      - name: Test
        run: cargo nextest run --all-features
        # Falls back to cargo test if nextest not installed
        continue-on-error: true

      - name: Test (fallback)
        if: failure()
        run: cargo test --all-features

      - name: Audit
        run: |
          cargo install cargo-audit --locked || true
          cargo audit

      - name: Schema check
        run: capnp compile -o- schema/mercury/v1/*.capnp
```

**Day 9 — GitHub Actions: Elixir CI**

```yaml
# .github/workflows/elixir.yml
name: Elixir CI

on:
  push:
    branches: [main]
    paths: ["apps/**", "mix.exs", "mix.lock"]
  pull_request:
    paths: ["apps/**", "mix.exs", "mix.lock"]

jobs:
  check:
    runs-on: ubuntu-latest
    env:
      MIX_ENV: test
    steps:
      - uses: actions/checkout@v4
      - uses: erlef/setup-beam@v1
        with:
          otp-version: "27.0"
          elixir-version: "1.17"

      - name: Cache deps
        uses: actions/cache@v4
        with:
          path: |
            deps
            _build
          key: mix-${{ hashFiles('mix.lock') }}

      - run: mix deps.get
      - run: mix compile --warnings-as-errors

      - name: Format check
        run: mix format --check-formatted

      - name: Credo
        run: mix credo --strict

      - name: Dialyzer
        run: mix dialyzer

      - name: Test
        run: mix test --cover
```

**Day 10 — Branch protection & merge rules**

- GitHub repo settings:
  - Require PR reviews (1 reviewer minimum)
  - Require status checks: `Rust CI / check`, `Elixir CI / check`
  - Require branches to be up to date before merging
  - No direct pushes to `main`

**Day 11 — Coverage reporting**

Add `cargo-llvm-cov` to Rust CI:

```yaml
      - name: Coverage
        run: |
          cargo install cargo-llvm-cov --locked || true
          cargo llvm-cov --all-features --lcov --output-path lcov.info

      - name: Upload coverage
        uses: codecov/codecov-action@v4
        with:
          files: lcov.info
          flags: rust
```

Add `excoveralls` to Elixir CI:

```yaml
      - name: Test with coverage
        run: mix coveralls.json

      - name: Upload coverage
        uses: codecov/codecov-action@v4
        with:
          files: cover/excoveralls.json
          flags: elixir
```

---

### Days 12–15: Development Environment (Step 0.4)

**Day 12 — Docker Compose**

```yaml
# docker-compose.yml
services:
  scylladb:
    image: scylladb/scylla:6.0
    ports:
      - "9042:9042"    # CQL
    command: --smp 2 --memory 2G --overprovisioned 1
    volumes:
      - scylla_data:/var/lib/scylla
    healthcheck:
      test: ["CMD", "cqlsh", "-e", "SELECT now() FROM system.local"]
      interval: 10s
      timeout: 5s
      retries: 10

  postgresql:
    image: citusdata/citus:12.1
    ports:
      - "5432:5432"
    environment:
      POSTGRES_USER: mercury
      POSTGRES_PASSWORD: mercury_dev
      POSTGRES_DB: mercury_dev
    volumes:
      - pg_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U mercury"]
      interval: 5s
      timeout: 3s
      retries: 5

  nats:
    image: nats:2.10-alpine
    ports:
      - "4222:4222"    # Client
      - "8222:8222"    # Monitoring
    command: --jetstream --store_dir /data
    volumes:
      - nats_data:/data

  dragonfly:
    image: docker.dragonflydb.io/dragonflydb/dragonfly:latest
    ports:
      - "6379:6379"
    ulimits:
      memlock: -1

  redpanda:
    image: redpandadata/redpanda:v24.1.1
    ports:
      - "9092:9092"    # Kafka API
      - "8081:8081"    # Schema Registry
      - "8082:8082"    # REST Proxy
    command:
      - redpanda start
      - --smp 1
      - --memory 1G
      - --overprovisioned
      - --kafka-addr 0.0.0.0:9092
      - --advertise-kafka-addr localhost:9092
    volumes:
      - redpanda_data:/var/lib/redpanda/data

volumes:
  scylla_data:
  pg_data:
  nats_data:
  redpanda_data:
```

Verify: `docker compose up -d` — all 5 services healthy.

**Day 13 — Makefile**

```makefile
# Makefile
.PHONY: dev test lint bench schema-gen clean

# Start all development dependencies
dev:
	docker compose up -d
	@echo "Waiting for services..."
	@sleep 5
	@docker compose ps

# Run all tests (Rust + Elixir)
test: test-rust test-elixir

test-rust:
	cargo nextest run --all-features 2>/dev/null || cargo test --all-features

test-elixir:
	mix test

# Lint everything
lint: lint-rust lint-elixir lint-schema

lint-rust:
	cargo fmt --all -- --check
	cargo clippy --all-targets --all-features -- -D warnings

lint-elixir:
	mix format --check-formatted
	mix credo --strict

lint-schema:
	capnp compile -o- schema/mercury/v1/*.capnp

# Generate code from Cap'n Proto schemas
schema-gen:
	cargo build -p mercury-core 2>&1 | head -20
	@echo "Schema codegen complete (Rust)"

# Run benchmarks
bench:
	cargo bench --all-features

# Clean everything
clean:
	cargo clean
	mix clean
	docker compose down -v

# Stop dev services
stop:
	docker compose down
```

Verify: `make dev && make test && make lint` — all green.

**Day 14 — Toolchain version pinning**

```toml
# .mise.toml (or .tool-versions)
[tools]
rust = "1.85"
erlang = "27.0"
elixir = "1.17"

[env]
RUST_LOG = "debug"
DATABASE_URL = "postgres://mercury:mercury_dev@localhost:5432/mercury_dev"
SCYLLA_CONTACT_POINTS = "localhost:9042"
NATS_URL = "nats://localhost:4222"
DRAGONFLY_URL = "redis://localhost:6379"
REDPANDA_BROKERS = "localhost:9092"
```

```toml
# rust-toolchain.toml
[toolchain]
channel = "1.85"
components = ["clippy", "rustfmt"]
```

**Day 15 — Smoke test & final verification**

Run the full acceptance criteria checklist:

```bash
# 1. Start all dependencies
make dev
# Expected: 5 containers running (scylladb, postgresql, nats, dragonfly, redpanda)

# 2. Run all tests
make test
# Expected: Rust tests pass, Elixir tests pass

# 3. Lint everything
make lint
# Expected: Zero warnings, zero errors

# 4. Schema codegen
make schema-gen
# Expected: Rust code generated from .capnp files

# 5. Verify CI locally (optional, with act)
# act -j check
```

Commit and push. CI should go green on the first run.

---

## Deliverables Checklist

| # | Deliverable | Verify With |
|---|-------------|-------------|
| 1 | Rust workspace with 6 crates compiling | `cargo check` |
| 2 | Elixir umbrella with 3 apps compiling | `mix compile` |
| 3 | 5 Cap'n Proto schemas compiling | `capnp compile -o- schema/mercury/v1/*.capnp` |
| 4 | Rust codegen from schemas | `cargo build -p mercury-core` |
| 5 | GitHub Actions: Rust CI (lint, test, audit, schema) | Push a PR |
| 6 | GitHub Actions: Elixir CI (lint, credo, dialyzer, test) | Push a PR |
| 7 | Branch protection on `main` | GitHub settings |
| 8 | Coverage reporting (Codecov) | PR check |
| 9 | Docker Compose with 5 services | `docker compose up -d && docker compose ps` |
| 10 | Makefile with all targets | `make dev && make test && make lint` |
| 11 | Toolchain pinning (mise/rust-toolchain) | `mise install` or `rustup show` |
| 12 | ADR-001: Monorepo decision | `cat docs/adr/001-monorepo.md` |
| 13 | `.gitignore` covering Rust + Elixir + OS | `git status` is clean |

---

## Risk Mitigations for Phase 0

| Risk | Mitigation |
|------|-----------|
| Cap'n Proto Rust crate version mismatch | Pin `capnp` and `capnpc` to same version in `Cargo.toml` |
| ScyllaDB slow to start in Docker | `healthcheck` with retries; `make dev` waits 5s |
| Citus Docker image compatibility | Use official `citusdata/citus` image, test `CREATE EXTENSION citus` on startup |
| CI flakiness from network deps | Cache Rust/Elixir deps aggressively; `cargo audit` can be allowed to soft-fail |
| Elixir/Rust toolchain drift between devs | `mise` or `rust-toolchain.toml` enforces exact versions |

---

## What's Next (Phase 1 Readiness)

After Phase 0 is complete, Phase 1 starts immediately in the existing crates:

- `mercury-core` → Domain types (`MessageId`, `ChannelId`, `TenantId`, `TimeBucket`)
- `mercury-crdt` → HLC, GCounter, LWWRegister, ORSet, ReactionMap, MessageLog
- `mercury-crypto` → `NoopEncryptor` stub

All schemas are defined, CI is green, dev environment is running. Phase 1 is pure Rust domain logic — no networking, no databases, just types, validation, and benchmarks.
