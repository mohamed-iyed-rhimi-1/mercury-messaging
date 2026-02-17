# Phase 7: Infrastructure & Hardening

## Scope

Production-ready deployment with containerization, Kubernetes (k3s for dev/staging,
full k8s for production), observability, security hardening, and performance
optimization. After this phase, Mercury is ready for public beta.

**k3s** is the primary deployment target — lightweight Kubernetes that runs on a
single node or small cluster. Same Kubernetes API, same manifests, 1/10th the
resource overhead. Production can upgrade to full k8s or EKS/GKE without manifest
changes.

---

## Steps

### 7.1 — Dockerfiles (Multi-Stage Builds)

Containerize the Elixir gateway and create production-ready images.

**Deliverables:**

- `infra/docker/Dockerfile.gateway` — Elixir gateway (multi-stage):
  - Stage 1: `elixir:1.18-otp-27-slim` — compile deps, build release
  - Stage 2: Rust builder — compile NIFs for target platform
  - Stage 3: `debian:bookworm-slim` — runtime only, non-root user
  - Final image target: <150MB
- `infra/docker/Dockerfile.sdk-builder` — WASM build image:
  - Rust + wasm-pack + Bun
  - Used in CI only, not deployed
- Health check endpoints:
  - `GET /health/live` — process alive (always 200)
  - `GET /health/ready` — connected to ScyllaDB + PostgreSQL + NATS
- Environment variable configuration:
  - `DATABASE_URL` — PostgreSQL connection string
  - `SCYLLA_NODES` — comma-separated ScyllaDB contact points
  - `NATS_URL` — NATS server URL
  - `DRAGONFLY_URL` — Dragonfly/Redis URL
  - `SECRET_KEY_BASE` — Phoenix secret
  - `PHX_HOST` — public hostname
  - `PORT` — listen port (default 4000)

---

### 7.2 — k3s Cluster Setup

Local and staging deployment on k3s.

**Deliverables:**

- `infra/k3s/install.sh` — single-node k3s install script:
  - Installs k3s with embedded etcd (no external deps)
  - Enables Traefik ingress (built into k3s)
  - Configures local storage provisioner
- `infra/k3s/README.md` — setup guide for dev/staging
- Cluster requirements:
  - Dev: 1 node, 4 CPU, 8GB RAM (runs everything including databases)
  - Staging: 3 nodes, 8 CPU, 16GB RAM each
  - Production: upgrade to EKS/GKE — same manifests, different cluster

**Why k3s:**
- Same Kubernetes API — manifests work on k3s, k8s, EKS, GKE
- 512MB RAM footprint vs 2GB+ for full k8s control plane
- Single binary install, no external etcd/containerd setup
- Built-in Traefik ingress, CoreDNS, local-path storage
- CNCF certified — not a toy, used in production at scale

---

### 7.3 — Kubernetes Manifests

Kubernetes resources for all Mercury services. Same manifests for k3s and k8s.

**Directory structure:**
```
infra/k8s/
├── namespace.yaml
├── gateway/
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── hpa.yaml
│   └── configmap.yaml
├── scylladb/
│   ├── statefulset.yaml
│   ├── service.yaml
│   └── configmap.yaml
├── postgresql/
│   ├── statefulset.yaml
│   ├── service.yaml
│   └── init-configmap.yaml
├── nats/
│   ├── statefulset.yaml
│   └── service.yaml
├── dragonfly/
│   ├── deployment.yaml
│   └── service.yaml
├── redpanda/
│   ├── statefulset.yaml
│   └── service.yaml
├── ingress.yaml
└── secrets.yaml          (template — actual values via sealed-secrets or external-secrets)
```

**Key design decisions:**
- All containers have resource limits (NASA Rule #3):
  - Gateway: 500m-2 CPU, 512Mi-2Gi RAM
  - ScyllaDB: 2-4 CPU, 4-8Gi RAM
  - PostgreSQL: 500m-2 CPU, 1-4Gi RAM
  - NATS: 100m-500m CPU, 128Mi-512Mi RAM
  - Dragonfly: 500m-2 CPU, 1-4Gi RAM
  - Redpanda: 1-2 CPU, 2-4Gi RAM
- Pod disruption budgets: `minAvailable: 1` for all stateful services
- Anti-affinity: spread database pods across nodes (staging/prod)
- Gateway HPA: scale on CPU (70%) and WebSocket connection count
- Liveness/readiness probes on all pods

---

### 7.4 — Observability Stack

OpenTelemetry-based observability deployed on the same k3s cluster.

**Deliverables:**

- `infra/k8s/observability/` directory:
  - Prometheus (metrics collection) — via kube-prometheus-stack Helm chart
  - Grafana (dashboards) — bundled with kube-prometheus-stack
  - Loki (log aggregation) — lightweight, fits k3s
  - Tempo (distributed tracing) — Grafana's trace backend
- Elixir gateway instrumentation:
  - `OpentelemetryPhoenix` — auto-instrument Phoenix channels
  - `OpentelemetryEcto` — auto-instrument PostgreSQL queries
  - Custom telemetry for ScyllaDB, NATS, Dragonfly
  - Structured JSON logging with correlation IDs
- Grafana dashboards:
  - Gateway: connections, msg/sec, latency P50/P95/P99, rate limit triggers
  - ScyllaDB: read/write latency, compaction, disk usage
  - PostgreSQL: query latency, connection pool, active queries
  - NATS: consumer lag, msg/sec, stream size
  - Dragonfly: hit rate, memory, ops/sec
  - System: CPU, memory, network per pod
- Alerting rules (Prometheus AlertManager):
  - Gateway P99 >100ms
  - Error rate >1%
  - ScyllaDB node down
  - NATS consumer lag >10K messages
  - Dragonfly memory >80%
  - Pod restart count >3 in 5min

---

### 7.5 — Health Checks & Readiness

Production health check system for the gateway.

**Deliverables:**

- `GET /health/live` — returns 200 if BEAM VM is running
- `GET /health/ready` — checks all dependencies:
  - ScyllaDB: `SELECT now() FROM system.local`
  - PostgreSQL: `SELECT 1`
  - NATS: connection alive
  - Dragonfly: `PING`
- `GET /health/startup` — same as ready, used for startup probe
  (gives slow services like ScyllaDB time to initialize)
- Kubernetes probe configuration:
  - `livenessProbe`: `/health/live`, period 10s, failure 3
  - `readinessProbe`: `/health/ready`, period 5s, failure 2
  - `startupProbe`: `/health/startup`, period 5s, failure 30 (allows 150s startup)

---

### 7.6 — Security Hardening

**Deliverables:**

- Container security:
  - Non-root user in all Dockerfiles (`USER nobody`)
  - Read-only root filesystem where possible
  - No `CAP_NET_RAW` or other unnecessary capabilities
  - `securityContext` in all pod specs
- Secret management:
  - `sealed-secrets` controller for encrypting secrets in git
  - Or `external-secrets` operator for pulling from AWS Secrets Manager
  - Template `secrets.yaml` with placeholders
- Network policies:
  - Gateway → ScyllaDB, PostgreSQL, NATS, Dragonfly, Redpanda (allow)
  - ScyllaDB → ScyllaDB (inter-node, allow)
  - All other pod-to-pod traffic denied
- Dependency scanning:
  - `cargo audit` in CI
  - `mix audit` in CI (via `mix_audit` package)
  - Trivy container image scanning
- TLS:
  - cert-manager for automatic Let's Encrypt certificates
  - TLS termination at Traefik ingress (k3s) or Envoy (k8s)
  - Internal traffic: mTLS via service mesh (optional, Phase 7+)

---

### 7.7 — CI/CD Pipeline

GitHub Actions pipeline for build, test, and deploy.

**Deliverables:**

- `.github/workflows/ci.yml` — runs on every PR:
  - Rust: fmt, clippy, test, audit
  - Elixir: fmt, credo, dialyzer, unit tests
  - SDK: tsc, bun test
  - WASM: wasm-pack build + size check
  - Integration tests (docker-compose services)
  - Container image build (no push)
- `.github/workflows/deploy.yml` — runs on merge to main:
  - Build + push container images to registry (GHCR or ECR)
  - Tag with git SHA + `latest`
  - Deploy to k3s staging via `kubectl apply` (or ArgoCD)
- `.github/workflows/release.yml` — manual trigger:
  - Semantic version tag
  - Build + push production images
  - npm publish `@mercury/sdk`
  - Deploy to production cluster

---

### 7.8 — Load Testing

Validate performance targets under production-like load.

**Deliverables:**

- `tests/load/` directory:
  - k6 scripts for WebSocket load testing
  - Scenarios:
    - Ramp to 10K concurrent connections, 5K msg/sec sustained 10min
    - Burst: 50K connections in 60s
    - Message history: 1K concurrent reads
    - Sync: 500 concurrent reconnect+sync cycles
- Performance targets (single gateway node, 4 CPU / 8GB):
  - 10K concurrent WebSocket connections
  - 5K msg/sec sustained
  - P99 message delivery <100ms
  - P99 history fetch <50ms
- Results documented in `docs/benchmarks/phase-7-load-test.md`

---

### 7.9 — Tombstone GC & Maintenance Jobs

Background jobs deferred from Phase 5.

**Deliverables:**

- `apps/gateway/lib/gateway/gc_worker.ex` — GenServer:
  - Runs every 6 hours
  - Deletes ScyllaDB tombstones older than 30 days
  - Cleans expired sync cursors (no activity for 90 days)
  - Bounded: max 10K deletes per run (NASA Rule #2)
- `apps/gateway/lib/gateway/metrics_reporter.ex` — GenServer:
  - Pushes Prometheus metrics every 15s
  - Connection count, message rate, queue depth

---

### 7.10 — ADR-010 & ADR-011

- ADR-010: "k3s for dev/staging, upgrade path to production k8s"
- ADR-011: "Observability stack: Prometheus + Grafana + Loki + Tempo"

---

## Acceptance Criteria

| # | Criterion | Verification |
|---|-----------|-------------|
| 1 | Gateway Docker image builds and runs | `docker build` + `docker run` + health check |
| 2 | k3s cluster runs all services | `kubectl get pods` — all Running |
| 3 | Gateway connects to all dependencies in k3s | `/health/ready` returns 200 |
| 4 | HPA scales gateway on load | k6 load test triggers scale-up |
| 5 | Grafana dashboards show all metrics | Manual verification |
| 6 | Alerts fire on simulated failure | Kill a pod, verify alert |
| 7 | Network policies block unauthorized traffic | `kubectl exec` curl test |
| 8 | CI pipeline passes on clean PR | GitHub Actions green |
| 9 | Container images <150MB (gateway) | `docker images` check |
| 10 | Load test: 10K connections, 5K msg/sec, P99 <100ms | k6 results |
| 11 | Tombstone GC runs without errors | Log verification |
| 12 | ADR-010, ADR-011 written | Files exist |
| 13 | All existing tests still pass (195+) | Full quality gate |

---

## Quality Gates

- Rust: fmt, clippy, test, audit — 0 issues
- Elixir: fmt, credo, dialyzer, unit + integration tests — 0 failures
- SDK: tsc, bun test — 0 failures
- Docker: images build, health checks pass
- k3s: all pods Running, probes healthy
- Load: meets performance targets

---

## k3s vs k8s Decision Matrix

| Aspect | k3s | Full k8s (EKS/GKE) |
|--------|-----|---------------------|
| Install | Single binary, 30s | Managed service, 15min |
| RAM overhead | ~512MB | ~2-4GB |
| API compatibility | 100% (CNCF certified) | 100% |
| Ingress | Traefik built-in | ALB/Nginx/Envoy |
| Storage | local-path built-in | EBS/PD CSI drivers |
| Best for | Dev, staging, edge, small prod | Large-scale production |
| Manifest changes | None | None (same YAML) |
| Upgrade path | `kubectl apply` same manifests on EKS | N/A |

**Strategy:** Develop and test on k3s. When scale demands it, deploy same
manifests to EKS/GKE. Zero manifest changes required.

---

## Dependency Order

```
7.1 (Dockerfiles) ──┐
                     ├──▶ 7.3 (K8s manifests) ──▶ 7.2 (k3s setup) ──▶ 7.4 (Observability)
7.5 (Health checks) ─┘                                                       │
                                                                              ▼
7.6 (Security) ──────────────────────────────────────────────────────▶ 7.7 (CI/CD)
                                                                              │
7.9 (GC/Maintenance) ───────────────────────────────────────────────────────┘
                                                                              │
7.8 (Load testing) ◀─────────────────────────────────────────────────────────┘
                                                                              │
7.10 (ADRs) ◀────────────────────────────────────────────────────────────────┘
```

7.1 + 7.5 can start in parallel. 7.6 can start anytime.
7.3 depends on 7.1. 7.2 depends on 7.3. 7.4 depends on 7.2.
7.7 depends on 7.1 + 7.6. 7.8 depends on 7.2 + 7.4.

---

## Timeline Estimate

- Step 7.1: 2-3 days (Dockerfiles, health endpoints)
- Step 7.2: 1-2 days (k3s setup script)
- Step 7.3: 3-4 days (all K8s manifests)
- Step 7.4: 3-4 days (observability stack + dashboards)
- Step 7.5: 1 day (health check endpoints)
- Step 7.6: 2-3 days (security hardening)
- Step 7.7: 2-3 days (CI/CD pipelines)
- Step 7.8: 2-3 days (load testing)
- Step 7.9: 1-2 days (GC worker, metrics reporter)
- Step 7.10: 1 day (ADRs)

**Total: ~18-25 working days**

---

## Risk Assessment

| Risk | Impact | Mitigation |
|------|--------|------------|
| Rust NIF cross-compilation for Docker | High | Multi-stage build with matching target arch |
| ScyllaDB on k3s local storage | Medium | Use hostPath volumes, accept single-node limitation for dev |
| k3s Traefik WebSocket limits | Medium | Configure Traefik annotations for WS upgrade + timeouts |
| WASM build in CI is slow (~60s) | Low | Cache cargo registry + target dir |
| k3s → k8s migration gaps | Low | Test manifests on both, use only standard K8s APIs |
