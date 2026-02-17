# ADR-002: ULID over UUIDv7 for MessageId

## Status: Accepted

## Context
We need sortable, unique message IDs that can be generated client-side (offline-first).
Both ULID and UUIDv7 embed a timestamp and provide lexicographic ordering.

## Decision
Use ULID (Universally Unique Lexicographically Sortable Identifier).

## Consequences
- **Easier:** Crockford Base32 encoding is case-insensitive and URL-safe (26 chars vs
  36 for UUID). Monotonic sort within same millisecond. Widely supported `ulid` crate.
- **Harder:** Not an IETF standard (UUIDv7 is RFC 9562). Slightly less ecosystem
  support in databases that have native UUID types. We store as 16-byte blobs in
  ScyllaDB so this doesn't matter in practice.
