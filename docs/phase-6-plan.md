# Phase 6: Web SDK (`@anthropic/mercury-sdk`)

## Scope

Build the JavaScript/TypeScript Web SDK only. iOS and Android SDKs deferred.

The SDK is an npm package that third-party developers integrate into their web apps.
It connects to the Mercury gateway via Phoenix WebSocket channels, handles MLS
encryption client-side, manages offline message queuing, and syncs via CRDTs.

Architecture: **Rust core compiled to WASM** (crypto, CRDT, validation) +
**TypeScript wrapper** (WebSocket transport, IndexedDB storage, public API).

```
@mercury/sdk (npm package)
├── mercury-sdk-core (Rust → WASM via wasm-bindgen)
│   ├── MLS encrypt/decrypt (openmls)
│   ├── CRDT merge (mercury-crdt)
│   ├── Message validation (mercury-core)
│   ├── HLC clock
│   └── Delta serialization
└── TypeScript wrapper
    ├── MercuryClient (public API)
    ├── PhoenixSocket transport
    ├── IndexedDB local store
    ├── Offline queue
    └── Web Worker for WASM
```

---

## Steps

### 6.1 — `mercury-sdk-core` Rust Crate (WASM target)

New crate at `crates/mercury-sdk-core/`. Compiles to WASM via `wasm-bindgen`.
Exposes a minimal FFI surface to JavaScript — all crypto and CRDT logic stays in Rust.

**Deliverables:**
- `SdkCore` struct exposed via `#[wasm_bindgen]`:
  - `new(user_id: &str, device_id: &str) -> SdkCore`
  - `generate_message_id() -> String` (ULID)
  - `validate_message(content: &[u8], content_type: u8) -> Result<(), String>`
  - `compute_time_bucket(timestamp_ms: u64) -> u32`
  - `hlc_tick() -> JsValue` (returns `{wall, counter, node}`)
  - `hlc_merge(remote_wall: u64, remote_counter: u32) -> JsValue`
- MLS wrapper (delegates to `mercury-crypto`):
  - `create_mls_group(identity: &[u8]) -> Result<JsValue, String>`
  - `mls_encrypt(group_state: &[u8], plaintext: &[u8]) -> Result<Vec<u8>, String>`
  - `mls_decrypt(group_state: &[u8], ciphertext: &[u8]) -> Result<Vec<u8>, String>`
  - `generate_key_package(identity: &[u8]) -> Result<Vec<u8>, String>`
- CRDT merge functions:
  - `merge_deltas(local_state: &[u8], remote_deltas: &[u8]) -> Result<Vec<u8>, String>`
  - `create_delta(delta_type: &str, payload: &JsValue) -> Result<Vec<u8>, String>`

**Dependencies:**
- `mercury-core` (ids, validation, time bucket)
- `mercury-crdt` (HLC, delta types, merge)
- `mercury-crypto` (MLS via openmls)
- `wasm-bindgen`, `serde-wasm-bindgen`, `js-sys`, `web-sys`
- `getrandom = { features = ["js"] }` (for WASM random)

**Key constraints:**
- `openmls` must compile to `wasm32-unknown-unknown` — verify this first
- If openmls doesn't compile to WASM, stub MLS with `NoopEncryptor` and defer
  real client-side MLS to a follow-up (server-side MLS via gateway still works)
- Target WASM binary size: <500KB before gzip, <150KB gzipped

**Tests:**
- Rust unit tests run natively (`cargo test`)
- WASM integration tests via `wasm-pack test --headless --chrome`

---

### 6.2 — TypeScript SDK Package

New package at `sdks/mercury-sdk-js/`. Published as `@mercury/sdk` on npm.

**Project structure:**
```
sdks/mercury-sdk-js/
├── package.json
├── tsconfig.json
├── src/
│   ├── index.ts              # Public API exports
│   ├── client.ts             # MercuryClient class
│   ├── channel.ts            # Channel class (send, receive, history)
│   ├── transport.ts          # Phoenix WebSocket adapter
│   ├── store.ts              # IndexedDB local storage
│   ├── offline-queue.ts      # Offline message queue
│   ├── sync.ts               # Delta sync state machine
│   ├── worker.ts             # Web Worker for WASM core
│   └── types.ts              # Public TypeScript types
├── wasm/                     # Built WASM artifacts (gitignored, built by CI)
└── tests/
    ├── client.test.ts
    ├── channel.test.ts
    ├── store.test.ts
    ├── offline-queue.test.ts
    └── sync.test.ts
```

**Public API:**

```typescript
// Minimal, idiomatic TypeScript API
import { MercuryClient } from '@mercury/sdk'

const client = new MercuryClient({
  url: 'wss://gateway.example.com/ws',
  token: '<jwt>',
})

await client.connect()

const channel = client.channel('general')
await channel.join()

// Send
const { id } = await channel.send('hello world')

// Receive
channel.on('message', (msg) => {
  console.log(`${msg.sender}: ${msg.content}`)
})

// History
const messages = await channel.history({ limit: 50 })

// Typing indicator
channel.sendTyping()

// Read receipt
channel.markRead(msg.id)

// Sync (after offline period)
await channel.sync()

// Presence
channel.on('presence', (state) => { ... })

// Disconnect
client.disconnect()
```

---

### 6.3 — Phoenix WebSocket Transport Layer

Adapter that speaks the Phoenix Channel protocol over WebSocket.

**Deliverables:**
- `PhoenixTransport` class:
  - Implements Phoenix Channel wire protocol (join, push, reply, heartbeat)
  - JSON serialization (matching gateway's `Phoenix.Socket.Serializers.V2.JSON`)
  - Auto-reconnect with exponential backoff (1s, 2s, 4s, 8s, max 30s)
  - Heartbeat every 30s (matches gateway's `timeout: 60_000`)
  - Connection state machine: `disconnected → connecting → connected → disconnected`
- Maps SDK operations to channel events:
  - `channel.send()` → `msg:send`
  - `channel.history()` → `msg:history`
  - `channel.sendTyping()` → `msg:typing`
  - `channel.markRead()` → `msg:read`
  - `channel.sync()` → `sync:request` / `sync:push`
  - `channel.updateCursor()` → `sync:cursor`
- Incoming event handlers:
  - `msg:new` → `channel.on('message', ...)`
  - `msg:typing` → `channel.on('typing', ...)`
  - `msg:read` → `channel.on('read', ...)`
  - `mls:commit` → internal MLS state update
  - `mls:welcome` → internal MLS group join

**No external Phoenix JS dependency** — implement the minimal wire protocol
directly (~200 lines). The Phoenix JS client pulls in too many dependencies
and doesn't support Web Workers well.

---

### 6.4 — IndexedDB Local Store

Persistent local storage for offline-first operation.

**Deliverables:**
- `LocalStore` class using IndexedDB:
  - `messages` object store: keyed by `(channelId, messageId)`, indexed by timestamp
  - `syncState` object store: keyed by `channelId`, stores last HLC
  - `offlineQueue` object store: keyed by auto-increment, stores pending messages
  - `keyStore` object store: MLS group state, encrypted with SubtleCrypto
- Operations:
  - `writeMessage(channelId, message)` — upsert
  - `readMessages(channelId, { limit, before })` — paginated read
  - `getSyncState(channelId)` — last known HLC
  - `setSyncState(channelId, hlc)` — update after sync
  - `enqueue(message)` — add to offline queue
  - `dequeue(count)` — drain offline queue
  - `clearQueue(upToId)` — remove acknowledged messages
- Bounded: max 10,000 messages per channel in IndexedDB (oldest evicted)
- Encrypted at rest: MLS keys stored via `SubtleCrypto.wrapKey()` with
  a key derived from user credentials

---

### 6.5 — Offline Queue & Delta Sync

Client-side offline queue and sync state machine.

**Deliverables:**
- `OfflineQueue`:
  - Messages written to IndexedDB `offlineQueue` store when disconnected
  - On reconnect, drained in HLC order via `sync:push`
  - Server ACKs each batch → remove from queue
  - Bounded: max 10,000 pending messages (NASA Rule #2)
- `SyncEngine`:
  - State machine: `idle → syncing → idle`
  - On reconnect: send `sync:request` with last HLC per channel
  - Receive deltas → merge into local store (via WASM CRDT merge)
  - Push offline queue → receive ACKs
  - Update sync cursor via `sync:cursor`
- Conflict resolution handled entirely in WASM (Rust CRDT merge)

---

### 6.6 — Web Worker Integration

Run WASM core in a Web Worker to keep crypto off the main thread.

**Deliverables:**
- `MercuryWorker`: Web Worker that loads WASM module
  - Main thread sends commands via `postMessage`
  - Worker executes WASM functions, returns results
  - Commands: `encrypt`, `decrypt`, `merge_deltas`, `validate`, `generate_id`
- Fallback: if Web Workers unavailable (e.g., some SSR contexts),
  run WASM on main thread with a warning
- Message passing uses `Transferable` (ArrayBuffer) for zero-copy
  where possible

---

### 6.7 — Build & Package

**Deliverables:**
- `wasm-pack build` integrated into npm build script
- Bundled with `bun build`:
  - ESM output (primary)
  - TypeScript declarations (`.d.ts`)
  - WASM binary inlined as base64 or loaded from CDN
- Bundle size target: <200KB gzipped (WASM + JS)
- `package.json` with proper `exports` field, `types`, `sideEffects: false`
- Runtime/test runner: **Bun** (fast TS execution, built-in test runner, built-in bundler)

---

### 6.8 — Tests

| Level | What | Tool |
|-------|------|------|
| Rust unit | WASM FFI functions | `cargo test` + `wasm-pack test` |
| TS unit | Client, Channel, Store, Queue, Sync | `bun test` |
| TS integration | Full flow: connect → send → receive → offline → sync | `bun test` + mock WebSocket |
| E2E | SDK ↔ live gateway | `playwright` (deferred to Phase 7) |

---

### 6.9 — ADR-009

"Web SDK architecture: WASM core + TypeScript wrapper"

---

## Acceptance Criteria

| # | Criterion | Verification |
|---|-----------|-------------|
| 1 | `mercury-sdk-core` compiles to WASM | `wasm-pack build` succeeds |
| 2 | WASM binary <700KB uncompressed, <300KB gzipped | `ls -la` + `gzip` check |
| 3 | SDK connects to gateway, sends and receives messages | Integration test with live gateway |
| 4 | Messages encrypted client-side (MLS or Noop fallback) | Unit test |
| 5 | Offline queue persists messages in IndexedDB | Unit test |
| 6 | Delta sync works after reconnect | Unit test with mock transport |
| 7 | CRDT merge runs in WASM (not JS) | Worker test |
| 8 | Auto-reconnect with exponential backoff | Unit test |
| 9 | TypeScript types exported correctly | `tsc --noEmit` check |
| 10 | Bundle <300KB gzipped | Build output check |
| 11 | ADR-009 written | File exists |
| 12 | All existing tests still pass (155+) | Full quality gate |

---

## Quality Gates

- Rust: `cargo fmt`, `cargo clippy`, `cargo test`, `wasm-pack test`
- TypeScript: `tsc --noEmit`, `eslint`, `bun test`
- Bundle size: `<200KB gzipped`
- Existing: 81 Rust + 55 Elixir unit + 19 Elixir integration still pass

---

## Risk Assessment

| Risk | Impact | Mitigation |
|------|--------|------------|
| `openmls` doesn't compile to WASM | High | Stub with `NoopEncryptor`, defer client-side MLS |
| WASM binary too large (>500KB) | Medium | Tree-shake, `wasm-opt -Oz`, split MLS into lazy-loaded chunk |
| Phoenix channel protocol changes | Low | Pin Phoenix version, minimal protocol impl |
| IndexedDB quota limits | Low | Bounded stores, LRU eviction |

---

## Timeline Estimate

- Step 6.1: 3-4 days (WASM crate, verify openmls compiles)
- Step 6.2: 2-3 days (TypeScript package structure, public API types)
- Step 6.3: 2-3 days (Phoenix transport adapter)
- Step 6.4: 2 days (IndexedDB store)
- Step 6.5: 2-3 days (offline queue, sync engine)
- Step 6.6: 1-2 days (Web Worker)
- Step 6.7: 1 day (build, bundle)
- Step 6.8: 2-3 days (tests)
- Step 6.9: 0.5 day (ADR)

**Total: ~16-20 working days**

---

## Dependency Order

```
6.1 (WASM crate) ──┐
                    ├──▶ 6.6 (Web Worker) ──▶ 6.5 (Sync Engine) ──▶ 6.8 (Tests)
6.2 (TS package) ──┤                                                      │
                    ├──▶ 6.3 (Transport) ──────────────────────────────────┤
                    │                                                      │
                    └──▶ 6.4 (IndexedDB) ──────────────────────────────────┘
                                                                           │
6.7 (Build) ◀─────────────────────────────────────────────────────────────┘
6.9 (ADR) — anytime
```

Steps 6.1 and 6.2 can start in parallel. 6.3 and 6.4 can also run in parallel.
6.5 depends on 6.3 + 6.4 + 6.6. 6.7 and 6.8 are last.
