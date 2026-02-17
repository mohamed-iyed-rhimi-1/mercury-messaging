# ADR-005: Elixir-Native DB Clients over Rust NIFs for I/O

## Status: Accepted

## Context
Phase 3 adds database persistence (ScyllaDB, PostgreSQL, Dragonfly, NATS).
We could either expose Rust DB clients via NIFs or use Elixir-native clients.

## Decision
Use Elixir-native clients: Xandra (ScyllaDB), Ecto+Postgrex (PostgreSQL),
Redix (Dragonfly), Gnat (NATS). Keep Rust NIFs for CPU-bound work only
(validation, crypto, CRDT merge).

## Consequences
- **Easier:** BEAM excels at I/O concurrency — no dirty scheduler complexity.
  Elixir clients integrate naturally with supervision trees and backpressure.
  Ecto provides migrations, changesets, and query composition.
- **Harder:** Two languages for DB access (Rust benchmarks, Elixir production).
  Cannot share connection pools between NIF and Elixir code.
