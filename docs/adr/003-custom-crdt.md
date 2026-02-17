# ADR-003: Custom CRDT over Automerge for Message Ordering

## Status: Accepted

## Context
We need conflict-free data types for offline-first sync: message ordering, channel
membership, reactions, read positions, and profile fields. Automerge is a mature
general-purpose CRDT library with a Rust core.

## Decision
Implement 5 purpose-built CRDTs (HLC, GCounter, LWWRegister, ORSet, MessageLog)
instead of using Automerge.

## Consequences
- **Easier:** Smaller binary size (~10KB vs ~500KB for Automerge WASM). Full control
  over merge semantics — we only need 5 specific CRDTs, not a general document model.
  Simpler debugging. Property-based tests prove correctness of our specific merge rules.
- **Harder:** More code to maintain (~600 lines vs zero). No free undo/redo or rich
  text support. If we later need document-level CRDTs (collaborative editing), we'd
  need to add Automerge or Yjs at that point.
