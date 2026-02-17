# ADR-006: NATS + Redpanda over Kafka Alone

## Status: Accepted

## Context
We need both real-time event delivery (low latency) and durable event logging
(compliance, replay). Kafka can do both but has JVM GC pauses and operational
complexity.

## Decision
Use NATS JetStream for real-time events (microsecond latency, lightweight) and
Redpanda for durable audit logs (Kafka-compatible API, no JVM, C++ engine).

## Consequences
- **Easier:** NATS is ~3MB binary, trivial to operate. Redpanda is Kafka-compatible
  so existing tooling works. No JVM tuning. Sub-millisecond NATS delivery.
- **Harder:** Two systems to operate instead of one. Must ensure events flow
  from NATS to Redpanda reliably. Different client libraries.
