The cluster is already running. Here's how to operate it:

## Quick Status Check

bash
kubectl get pods -n mercury
kubectl get pods -n monitoring


## Full Startup (if cluster is stopped)

bash
# 1. Start k3d cluster
k3d cluster start mercury

# 2. Wait for all pods to come up
kubectl wait --for=condition=ready pod --all -n mercury --timeout=120s

# 3. Verify gateway clustering
for pod in $(kubectl get pods -n mercury -l app=gateway -o jsonpath='{.items[*].metadata.name}'); do
  peers=$(kubectl exec "$pod" -n mercury -- /app/bin/mercury rpc 'IO.write(length(Node.list()))')
  echo "$pod: $peers peer(s)"
done

# 4. Health check
curl -s http://localhost:30400/health/ready | jq


## Rebuild & Deploy (after code changes)

bash
cd ~/Desktop/mercury-messaging

# Build
docker build --no-cache -f infra/docker/Dockerfile.gateway -t mercury-gateway:v15-binary-ws .

# Import into k3d and restart pods
k3d image import mercury-gateway:v15-binary-ws -c mercury
kubectl delete pods -n mercury -l app=gateway
kubectl rollout status deployment/gateway -n mercury --timeout=120s


## Smoke Test

bash
bash scripts/smoke_test.sh


## Useful Commands

bash
# Gateway logs
kubectl logs -n mercury -l app=gateway --tail=50 -f

# Connect to a binary WebSocket (for manual testing)
# Generate a JWT first, then:
websocat --binary ws://localhost:30400/ws?token=<JWT>

# Prometheus metrics
curl -s http://localhost:30400/metrics | head -20

# Grafana dashboard
kubectl port-forward -n monitoring svc/grafana 3000:3000
# then open http://localhost:3000

# ScyllaDB shell
kubectl exec -it -n mercury scylladb-0 -- cqlsh

# PostgreSQL shell
kubectl exec -it -n mercury postgresql-0 -- psql -U mercury

# Dragonfly (Redis CLI)
kubectl exec -it -n mercury deploy/dragonfly -- redis-cli

# NATS
kubectl exec -it -n mercury nats-0 -- nats sub ">"


## Local Dev (without k3s)

bash
cd ~/Desktop/mercury-messaging

# Start dependencies via docker-compose (if you have one), or just:
mix run --no-halt
# Starts Bandit on port 4000, connects to local services


The gateway listens on port 4000 inside the pod, exposed as NodePort 30400 on your machine via k3d.
