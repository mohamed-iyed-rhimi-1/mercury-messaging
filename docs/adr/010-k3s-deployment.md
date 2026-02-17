# ADR-010: k3s for Dev/Staging, Upgrade Path to Production k8s

## Status: Accepted

## Context
Mercury needs a Kubernetes deployment for dev, staging, and production. Full k8s
(EKS/GKE) is expensive and complex for early development. We need a lightweight
option that uses the same manifests as production.

## Decision
Use k3s as the primary deployment target for dev and staging environments.

k3s is a CNCF-certified Kubernetes distribution that runs as a single binary
with ~512MB RAM overhead (vs 2-4GB for full k8s). It includes Traefik ingress,
CoreDNS, and local-path storage out of the box.

Key properties:
- 100% Kubernetes API compatible — same manifests work on k3s, k8s, EKS, GKE
- Single binary install (`curl -sfL https://get.k3s.io | sh -`)
- Embedded etcd — no external coordination service
- Built-in Traefik handles WebSocket upgrade for Phoenix channels

Upgrade path: when scale demands it, deploy the same `infra/k8s/` manifests
to EKS or GKE. Zero manifest changes required — only the cluster provider changes.

## Consequences

### Easier
- Dev environment matches production topology (same K8s API)
- Single-node setup for local development
- CI can spin up k3s for integration tests
- 10x less resource overhead than full k8s

### Harder
- k3s Traefik has different defaults than AWS ALB (need annotations)
- Local-path storage is not replicated (acceptable for dev/staging)
- Some k8s operators (e.g., ScyllaDB Operator) may need testing on k3s
