# Mercury Messaging

A production-grade, open-source messaging platform built with **Rust** and **Elixir** — designed for ultra-low latency, end-to-end encryption by default, and offline-first operation.

Mercury is an SDK-first platform: iOS, Android, and Web SDKs share a single Rust core compiled to native (via UniFFI) and WASM (via wasm-bindgen). Third-party developers embed Mercury into their own apps.

## Why Mercury

Existing messaging platforms make trade-offs we don't accept:

| Problem | Platform | Mercury's Answer |
|---------|----------|-----------------|
| GC latency spikes (10-40ms every 2min) | Discord (Go era) | Rust — zero garbage collection |
| E2EE off by default | Telegram | MLS (RFC 9420) — encrypted by default |
| Metadata exposure despite E2EE | WhatsApp | Sealed sender — server can't link sender/receiver |
| Extreme battery drain | Snapchat | QUIC + Cap'n Proto + lazy loading |
| Hot partition database failures | Discord (Cassandra) | ScyllaDB + time-bucketed partitions |
| Offline data loss | Most platforms | CRDTs — conflict-free sync, zero data loss |

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         SDK TIER                                 │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐                      │
│  │ iOS SDK  │  │ Android  │  │  JS SDK  │                      │
│  │ (Swift)  │  │ (Kotlin) │  │(TS+WASM) │                      │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘                      │
│       └──────────────┴──────┬──────┘                             │
│              mercury-sdk-core (Rust)                              │
│       Encryption · CRDT · Sync · Local DB · Protocol             │
└──────────────────────────┬──────────────────────────────────────┘
                           │ WebSocket (QUIC planned)
┌──────────────────────────┴──────────────────────────────────────┐
│                   GATEWAY TIER (Elixir/Phoenix)                  │
│       Connection mgmt · Presence · Rate limiting · Fan-out       │
│                    Rust NIFs for hot paths                        │
└──────────────────────────┬──────────────────────────────────────┘
                           │
┌──────────────────────────┴──────────────────────────────────────┐
│                     PERSISTENCE TIER                              │
│  ScyllaDB (messages) · PostgreSQL+Citus (users) · Dragonfly     │
│  NATS JetStream (real-time) · Redpanda (audit log)               │
└─────────────────────────────────────────────────────────────────┘
```

## Technology Stack

| Layer | Technology | Why |
|-------|-----------|-----|
| Core services | Rust | Zero GC, memory safety, predictable latency |
| Real-time gateway | Elixir/Phoenix | 2M+ concurrent connections, fault tolerance |
| Rust ↔ Elixir | Rustler NIFs | CPU-intensive crypto/CRDT in Rust, routing in Elixir |
| Encryption | MLS (RFC 9420) via `openmls` | Group E2EE, forward secrecy, post-compromise security |
| Messages DB | ScyllaDB | 10x Cassandra throughput, no GC pauses |
| Users DB | PostgreSQL + Citus | ACID, horizontal sharding |
| Local DB | SQLite + SQLCipher | Offline-first, encrypted at rest |
| Cache | Dragonfly | Redis-compatible, 25x faster, 80% less memory |
| Real-time events | NATS JetStream | Microsecond latency, 3-11M msg/sec |
| Durable log | Redpanda | Kafka-compatible, no JVM |
| Serialization | Cap'n Proto | Zero-copy, 70-90% smaller than JSON |
| Offline sync | CRDTs (custom Rust) | Conflict-free merge, delta sync |
| SDK FFI | UniFFI (mobile), wasm-bindgen (web) | Single Rust core → all platforms |

## Project Structure

```
mercury/
├── crates/                     # Rust workspace
│   ├── mercury-core/           # Domain types, validation, ULID, time-bucketing
│   ├── mercury-crypto/         # MLS encryption via openmls
│   ├── mercury-crdt/           # HLC, GCounter, LWWRegister, ORSet, MessageLog
│   ├── mercury-nif/            # Rustler NIFs (17 functions exposed to Elixir)
│   ├── mercury-sdk-core/       # Shared SDK engine (compiles to native + WASM)
│   ├── mercury-db/             # Database client abstractions
│   └── mercury-transport/      # Transport layer (QUIC planned)
├── apps/                       # Elixir umbrella
│   ├── gateway/                # Phoenix WebSocket gateway + Rust NIFs
│   ├── persistence/            # ScyllaDB + PostgreSQL + NATS consumers
│   ├── presence/               # Distributed presence tracking
│   └── fanout/                 # Message fan-out service
├── sdks/
│   └── mercury-sdk-js/         # TypeScript + WASM SDK (@mercury/sdk)
├── schema/                     # Cap'n Proto schema definitions
├── infra/
│   ├── docker/                 # Dockerfiles
│   ├── k8s/                    # Kubernetes manifests
│   ├── k3s/                    # k3s deployment configs
│   └── terraform/              # Infrastructure as code
├── tests/
│   ├── integration/            # Cross-service tests
│   ├── load/                   # k6/Gatling load tests
│   └── chaos/                  # Chaos engineering scenarios
├── docs/
│   ├── adr/                    # Architecture Decision Records (001-011)
│   └── phase-*-plan.md         # Implementation phase plans (0-7)
└── scripts/
    └── smoke_test.sh           # End-to-end smoke test suite
```

## Prerequisites

- [mise](https://mise.jdx.dev/) (manages all tool versions) or install manually:
  - Rust 1.93+
  - Erlang/OTP 27+
  - Elixir 1.17+
  - Cap'n Proto compiler (`capnp`)
- Docker & Docker Compose (for local dependencies)
- [Bun](https://bun.sh/) (for JS SDK development)

## Quick Start

```bash
# Clone
git clone https://github.com/iyed/mercury-messaging.git
cd mercury-messaging

# Install tool versions (if using mise)
mise install

# Start dependencies (ScyllaDB, PostgreSQL, NATS, Dragonfly, Redpanda)
make dev

# Initialize databases (first time only)
make db-init

# Build Rust NIFs
make nif

# Fetch Elixir deps and run
mix deps.get
iex -S mix
```

The gateway starts on `ws://localhost:4000/socket/websocket`.

## Development

```bash
# Run all tests (Rust + Elixir)
make test

# Run only Rust tests (101 tests)
make test-rust

# Run only Elixir tests
make test-elixir

# Lint everything (Rust fmt/clippy + Elixir format/credo + schema)
make lint

# Run Rust benchmarks
make bench

# JS SDK
cd sdks/mercury-sdk-js
bun install
bun test          # 37 tests
bun x tsc --noEmit  # typecheck
```

## Test Counts

| Suite | Tests | Status |
|-------|-------|--------|
| Rust | 101 | ✅ |
| Elixir (credo --strict) | 251 modules/functions | ✅ 0 issues |
| JS SDK | 37 | ✅ |
| Smoke tests | 44 | ✅ |

## Deployment

Mercury runs on Kubernetes. A k3s cluster config is included for development/staging.

```bash
# Build Docker image
docker build -f infra/docker/Dockerfile.gateway -t mercury/gateway .

# Deploy to k3s (see infra/k8s/ for full manifests)
kubectl apply -f infra/k8s/
```

The k8s deployment includes:
- Gateway (2 replicas, HPA)
- ScyllaDB, PostgreSQL, NATS, Dragonfly, Redpanda
- Prometheus + Grafana (monitoring namespace)
- Network policies, secrets, ingress

See [`docs/`](docs/) for detailed phase plans and [`docs/adr/`](docs/adr/) for architecture decision records.

## Observability

Mercury ships with full observability out of the box:

- **Tracing**: OpenTelemetry auto-instrumentation (Phoenix + Ecto), OTLP export
- **Metrics**: PromEx (44 Prometheus metrics), `/metrics` endpoint
- **Dashboards**: Grafana with auto-configured Prometheus datasource

## SDK Usage

### JavaScript/TypeScript

```bash
npm install @mercury/sdk
```

```typescript
import { MercuryClient } from '@mercury/sdk'

const client = new MercuryClient({
  tenantId: '<tenant-id>',
  apiKey: '<api-key>'
})
await client.connect()

const channel = client.channel('general')
await channel.send('hello')

channel.onMessage((message) => {
  console.log(`${message.sender}: ${message.text}`)
})
```

### iOS (Swift) — Planned

```swift
let client = try MercuryClient(config: .init(
    tenantId: "<tenant-id>",
    apiKey: "<api-key>"
))
try await client.connect()

let channel = try await client.channel("general")
try await channel.send("hello")
```

### Android (Kotlin) — Planned

```kotlin
val client = MercuryClient(
    tenantId = "<tenant-id>",
    apiKey = "<api-key>"
)
client.connect()

val channel = client.channel("general")
channel.send("hello")
```

## Architecture Decision Records

| ADR | Decision |
|-----|----------|
| [001](docs/adr/001-monorepo.md) | Monorepo over polyrepo |
| [002](docs/adr/002-ulid.md) | ULID over UUIDv7 for message IDs |
| [003](docs/adr/003-custom-crdt.md) | Custom CRDT over Automerge |
| [004](docs/adr/004-phoenix-pubsub.md) | Phoenix PubSub for fan-out |
| [005](docs/adr/005-elixir-db-clients.md) | Elixir DB clients (Ecto) over Rust |
| [006](docs/adr/006-nats-redpanda.md) | NATS + Redpanda over Kafka |
| [007](docs/adr/007-mls-over-signal.md) | MLS over Signal Protocol |
| [008](docs/adr/008-delta-sync-protocol.md) | Delta sync protocol design |
| [009](docs/adr/009-web-sdk-architecture.md) | Web SDK architecture |
| [010](docs/adr/010-k3s-deployment.md) | k3s for deployment |
| [011](docs/adr/011-observability-stack.md) | Observability stack choices |

## Implementation Status

Mercury is in active development. 25 of 29 architecture components are implemented.

**Completed**: Rust crates (core, crypto, crdt, nif), Elixir gateway (full message flow, presence, MLS handlers, CRDT sync), Dragonfly cache, Redpanda audit, JS SDK (offline-first + MLS), k3s cluster (9 services), observability stack.

**Deferred**: QUIC/WebTransport transport (WebSocket currently), Envoy service mesh, dedicated Rust DB/transport crates.

See [architecture.md](architecture.md) for the full implementation status breakdown.

## Contributing

We welcome contributions. Please read the guidelines below before submitting a PR.

1. Fork the repo and create a branch from `main`
2. Follow the coding standards:
   - Rust: `#![deny(warnings)]`, `clippy::pedantic`, format with `rustfmt`
   - Elixir: `mix format`, `mix credo --strict`, Dialyzer specs on public functions
   - All code follows [Tiger Style](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md) principles
3. Add tests for new functionality
4. Run `make lint && make test` before submitting
5. Write clear commit messages

### Development Workflow

```bash
# Create feature branch
git checkout -b feat/your-feature

# Make changes, then verify
make lint
make test

# Submit PR against main
```

## License

Mercury Messaging is licensed under the [GNU Affero General Public License v3.0](LICENSE) (AGPL-3.0).

This means you can freely use, modify, and distribute Mercury, but if you run a modified version as a network service, you must make your source code available to users of that service.
