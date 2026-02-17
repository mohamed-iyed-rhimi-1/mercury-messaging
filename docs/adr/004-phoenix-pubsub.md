# ADR-004: Phoenix PubSub over Dedicated Message Broker for Fan-out

## Status: Accepted

## Context
We need to route messages from sender to all channel members in real-time.
Options: Phoenix.PubSub (built-in :pg), NATS JetStream, or Redpanda/Kafka.

## Decision
Use Phoenix.PubSub for real-time intra-gateway fan-out. NATS and Redpanda are
added in Phase 3 for durable delivery and cross-service events.

## Consequences
- **Easier:** Zero additional infrastructure for Phase 2. Sub-millisecond routing.
  Native BEAM process monitoring for cleanup. No serialization overhead.
- **Harder:** PubSub is ephemeral (no replay). Limited to the Elixir cluster.
  Phase 3 adds NATS for durable delivery and cross-service communication.
