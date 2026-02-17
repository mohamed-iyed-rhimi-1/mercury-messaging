# ADR-009: Web SDK Architecture — WASM Core + TypeScript Wrapper

## Status: Accepted

## Context
Mercury needs a JavaScript/TypeScript SDK for web apps. The SDK must handle
MLS encryption, CRDT merge, message validation, and offline sync. These are
CPU-intensive operations that benefit from Rust's performance and correctness.

Options considered:
1. Pure TypeScript — simpler build, but reimplements crypto/CRDT logic
2. Rust → WASM + TypeScript wrapper — reuses existing Rust crates
3. Rust → WASM only — poor DX, no idiomatic TypeScript API

## Decision
Option 2: Rust WASM core (`mercury-sdk-core`) + thin TypeScript wrapper.

- `mercury-sdk-core` compiles to WASM via `wasm-pack`, exposing ID generation,
  validation, MLS KeyPackage generation, and delta validation
- TypeScript layer handles transport (Phoenix WebSocket), storage (IndexedDB),
  offline queue, sync state machine, and the public API
- `WasmBridge` class routes commands to a Web Worker (or main thread fallback)
- No Phoenix JS client dependency — minimal wire protocol implemented directly
- Bun used as runtime, test runner, and bundler

Key technical decisions:
- `openmls` compiles to WASM with the `js` feature (enables `fluvio-wasm-timer`)
- `getrandom` 0.2 needs `js` feature, 0.3 needs `wasm_js` feature + `--cfg`
- `uuid` needs `js` feature for WASM random
- `.cargo/config.toml` sets `getrandom_backend="wasm_js"` for wasm32 target
- `mercury-crypto` has a `wasm` feature flag — only SDK enables it

## Consequences

### Easier
- Crypto and CRDT logic shared between server NIFs and client WASM
- Single source of truth for validation rules
- TypeScript API is idiomatic — consumers don't know about WASM
- Web Worker keeps crypto off the main thread

### Harder
- WASM binary is 687KB uncompressed (274KB gzipped) — includes full MLS
- Build requires `wasm-pack` + Rust toolchain in CI
- Two dependency ecosystems (Cargo + npm) to maintain
- IndexedDB testing requires mocks (no native IDB in Bun/Node)
