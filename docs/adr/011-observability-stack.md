# ADR-011: Observability Stack — Prometheus + Grafana + Loki + Tempo

## Status: Accepted

## Context
Mercury needs production observability: metrics, logs, and traces. The stack
must run on k3s (resource-constrained) and scale to production k8s.

## Decision
All-Grafana stack: Prometheus (metrics), Loki (logs), Tempo (traces), Grafana (UI).

- Prometheus: scrapes `/metrics` endpoints, stores time-series data
- Loki: lightweight log aggregation (no full-text indexing, label-based)
- Tempo: distributed tracing backend (OpenTelemetry-compatible)
- Grafana: unified dashboards for all three signals

Deployed via kube-prometheus-stack Helm chart + Loki + Tempo Helm charts.

Elixir instrumentation:
- `opentelemetry_phoenix` — auto-instruments Phoenix channels
- `opentelemetry_ecto` — auto-instruments PostgreSQL queries
- Custom telemetry handlers for ScyllaDB, NATS, Dragonfly
- Structured JSON logging with correlation IDs via `Logger` metadata

## Consequences

### Easier
- Single UI (Grafana) for metrics, logs, and traces
- Loki is much lighter than Elasticsearch (fits k3s)
- Tempo is lighter than Jaeger for trace storage
- All components are open source, no vendor lock-in

### Harder
- Loki doesn't support full-text search (label-based only)
- Tempo requires sampling configuration for high-throughput
- kube-prometheus-stack Helm chart is complex to customize
