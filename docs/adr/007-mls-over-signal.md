# ADR-007: Why MLS over Signal Protocol for Group Encryption

## Status: Accepted

## Context
Mercury needs end-to-end encryption for all messages. The two leading options
are the Signal Protocol (used by WhatsApp, Signal) and MLS (RFC 9420, used by
Cisco WebEx, Wire, Google RCS).

Mercury is a multi-tenant SDK where channels can have up to 1,000 members.
Group encryption performance is critical.

## Decision
Use MLS (RFC 9420) via the `openmls` Rust library.

Key reasons:
1. **Group efficiency**: Signal Protocol requires O(n) encrypt operations for
   n-member groups (sender encrypts once per member). MLS uses a ratchet tree
   giving O(log n) operations for member add/remove.
2. **IETF standard**: MLS is RFC 9420 with formal security proofs. Signal
   Protocol is well-studied but not an IETF standard.
3. **Rust ecosystem**: `openmls` (v0.8) is actively maintained, supports all
   mandatory ciphersuites, and compiles to WASM for the web SDK.
4. **Multi-device native**: MLS treats each device as a separate leaf in the
   ratchet tree. Multi-device is a first-class concept, not bolted on.
5. **Forward secrecy + post-compromise security**: Both per-message (via
   sender ratchet) and per-epoch (via tree-based key schedule).

Ciphersuite: `MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519` (mandatory-to-implement).

## Consequences
- Server is a "delivery service" — stores KeyPackages, relays handshake
  messages, never sees plaintext or group keys.
- Group state lives client-side only (SQLCipher in Phase 5-6).
- `openmls` adds ~2.5MB to the Rust dependency tree.
- `test-utils` feature needed for Welcome message deserialization in tests.
- Member add/remove requires a Commit message fanned out to all members.
