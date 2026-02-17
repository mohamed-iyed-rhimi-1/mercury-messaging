#!/usr/bin/env bash
# Mercury k3s cluster setup — single-node dev/staging
# Usage: ./install.sh [--staging]
set -euo pipefail

STAGING="${1:-}"

echo "=== Installing k3s ==="
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server \
  --write-kubeconfig-mode 644 \
  --disable servicelb \
  --kube-apiserver-arg service-node-port-range=1-65535" \
  sh -

# Wait for k3s to be ready
echo "=== Waiting for k3s ==="
until kubectl get nodes 2>/dev/null | grep -q " Ready"; do
  sleep 2
done
echo "k3s is ready"

# Create mercury namespace
kubectl create namespace mercury --dry-run=client -o yaml | kubectl apply -f -

# Apply all manifests
echo "=== Deploying Mercury ==="
kubectl apply -f "$(dirname "$0")/../k8s/namespace.yaml"
kubectl apply -f "$(dirname "$0")/../k8s/secrets.yaml"
kubectl apply -f "$(dirname "$0")/../k8s/" --recursive

echo "=== Waiting for pods ==="
kubectl -n mercury wait --for=condition=ready pod --all --timeout=300s 2>/dev/null || true

echo "=== Status ==="
kubectl -n mercury get pods
echo ""
echo "Gateway: http://localhost:30400/health/live"
echo "Grafana: http://localhost:30300 (admin/mercury)"
