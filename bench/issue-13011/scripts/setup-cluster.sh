#!/usr/bin/env bash
# Create the kind cluster (if not already present) and install metrics-server.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

require_cmd kind kubectl

if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  log "kind cluster '$CLUSTER_NAME' already exists, skipping create"
else
  log "creating kind cluster '$CLUSTER_NAME'"
  kind create cluster --config "$MANIFESTS_DIR/kind-config.yaml"
fi

# kind sets the current context after create; assert we're talking to the right one.
ctx="$(kubectl config current-context)"
if [[ "$ctx" != "kind-$CLUSTER_NAME" ]]; then
  log "switching kubectl context to kind-$CLUSTER_NAME (was $ctx)"
  kubectl config use-context "kind-$CLUSTER_NAME" >/dev/null
fi

log "applying metrics-server"
kubectl apply -f "$MANIFESTS_DIR/metrics-server.yaml"

log "waiting for metrics-server Deployment to become Available (up to 180s)"
kubectl -n kube-system rollout status deploy/metrics-server --timeout=180s

# metrics-server takes a bit longer to start serving the metrics.k8s.io API
# than to report its Deployment Available. Poll `kubectl top` until it works.
log "waiting for metrics.k8s.io API to serve pod metrics"
deadline=$(( $(date +%s) + 180 ))
until kubectl top pod -n kube-system >/dev/null 2>&1; do
  if (( $(date +%s) > deadline )); then
    die "metrics.k8s.io API did not become ready within 180s"
  fi
  sleep 5
done

log "cluster ready"
