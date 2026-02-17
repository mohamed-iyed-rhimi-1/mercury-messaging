# Mercury k3s Deployment Guide

## Prerequisites

- Linux host (Ubuntu 22.04+ recommended) or macOS with Lima/Multipass
- 4 CPU, 8GB RAM minimum (dev)
- Docker images built and available (local registry or GHCR)

## Quick Start

### 1. Install k3s

```bash
chmod +x infra/k3s/install.sh
./infra/k3s/install.sh
```

Verify:

```bash
kubectl get nodes
# NAME     STATUS   ROLES                  AGE   VERSION
# myhost   Ready    control-plane,master   30s   v1.29.x+k3s1
```

### 2. Deploy Mercury

```bash
# Create namespace and secrets
kubectl apply -f infra/k8s/namespace.yaml

# Edit secrets with real values, then apply
cp infra/k8s/secrets.yaml /tmp/mercury-secrets.yaml
# Edit /tmp/mercury-secrets.yaml with base64-encoded values
kubectl apply -f /tmp/mercury-secrets.yaml

# Deploy databases first
kubectl apply -f infra/k8s/scylladb/
kubectl apply -f infra/k8s/postgresql/
kubectl apply -f infra/k8s/nats/
kubectl apply -f infra/k8s/dragonfly/
kubectl apply -f infra/k8s/redpanda/

# Wait for databases to be ready
kubectl -n mercury wait --for=condition=ready pod -l app=scylladb --timeout=120s
kubectl -n mercury wait --for=condition=ready pod -l app=postgresql --timeout=60s

# Deploy gateway
kubectl apply -f infra/k8s/gateway/
kubectl apply -f infra/k8s/ingress.yaml
kubectl apply -f infra/k8s/network-policies.yaml

# Deploy observability
kubectl apply -f infra/k8s/observability/
```

### 3. Verify

```bash
# All pods running
kubectl -n mercury get pods

# Health check
curl http://localhost:30400/health/ready

# Grafana dashboard
open http://localhost:30300
```

## Architecture

```
┌─────────────────────────────────────────────┐
│                  k3s node                    │
│                                              │
│  ┌──────────┐  ┌──────────┐  ┌───────────┐ │
│  │ Gateway  │  │ Gateway  │  │  Traefik   │ │
│  │ (pod 1)  │  │ (pod 2)  │  │ (ingress)  │ │
│  └────┬─────┘  └────┬─────┘  └─────┬─────┘ │
│       └──────┬───────┘              │        │
│              ▼                      │        │
│  ┌──────────────────────────────────┘        │
│  │                                           │
│  ▼          ▼          ▼          ▼          │
│ ScyllaDB  PostgreSQL  NATS    Dragonfly      │
│                                              │
│  Prometheus → Grafana → Loki → Tempo         │
└──────────────────────────────────────────────┘
```

## Endpoints

| Service     | Port  | Access              |
|-------------|-------|---------------------|
| Gateway WS  | 30400 | `ws://host:30400/ws`|
| Grafana     | 30300 | `http://host:30300` |
| Prometheus  | 9090  | Internal only       |

## Scaling

The gateway HPA auto-scales from 2 to 10 replicas based on CPU usage (70% threshold):

```bash
kubectl -n mercury get hpa
```

## Upgrading to Production k8s

Same manifests work on EKS/GKE. Only changes needed:

1. Replace `local-path` StorageClass with cloud provider (e.g., `gp3`, `pd-ssd`)
2. Replace `NodePort` services with `LoadBalancer` or use cloud ingress
3. Increase replica counts and resource limits
4. Add node affinity rules for database pods

```bash
# Deploy to EKS — same manifests
kubectl apply -f infra/k8s/namespace.yaml
kubectl apply -f infra/k8s/
```

## Troubleshooting

```bash
# Check pod logs
kubectl -n mercury logs -l app=gateway --tail=50

# Check pod events
kubectl -n mercury describe pod <pod-name>

# ScyllaDB status
kubectl -n mercury exec scylladb-0 -- nodetool status

# NATS status
kubectl -n mercury exec nats-0 -- nats server info
```
