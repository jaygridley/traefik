#!/usr/bin/env bash
# Install or upgrade Traefik to a specific image tag (e.g. v3.0.4, v3.1.7, v3.6.2).
# Usage: install-traefik.sh <image-tag>
set -euo pipefail
source "$(dirname "$0")/lib.sh"

require_cmd helm kubectl

VERSION="${1:?usage: install-traefik.sh <image-tag, e.g. v3.0.4>}"

# Idempotent. helm repo add returns non-zero if already added on some helm
# versions; ignore it.
helm repo add traefik https://traefik.github.io/charts >/dev/null 2>&1 || true
helm repo update traefik >/dev/null

log "installing/upgrading Traefik with image.tag=$VERSION replicas=$TRAEFIK_REPLICAS"
# Notes on the flags:
#  - We override only image.tag — chart appVersion is ignored. The chart's
#    bundled CRDs work across the 3.0–3.6 range.
#  - Both providers enabled because the issue affects both kubernetes and
#    kubernetescrd; we use Ingress here but the CRD provider must be on so the
#    `Middleware` annotation lookup resolves.
#  - resources.* unset (helm default) — we measure CPU absolute, not throttled.
#  - logs at ERROR to keep capture-time noise down.
helm upgrade --install traefik traefik/traefik \
  --namespace "$TRAEFIK_NS" --create-namespace \
  --set "image.tag=$VERSION" \
  --set "deployment.replicas=$TRAEFIK_REPLICAS" \
  --set providers.kubernetesIngress.enabled=true \
  --set providers.kubernetesCRD.enabled=true \
  --set ingressClass.enabled=true \
  --set ingressClass.isDefaultClass=true \
  --set service.type=ClusterIP \
  --set "logs.general.level=ERROR" \
  --wait --timeout 180s

log "waiting for Traefik rollout"
kubectl -n "$TRAEFIK_NS" rollout status deploy/traefik --timeout=180s

# Verify both kubernetes providers are actually enabled on the running pod.
# The chart renders --set providers.kubernetesIngress.enabled=true into a
# lowercased CLI flag (--providers.kubernetesingress=true). Fail fast if a
# future chart default drops either, so we don't capture meaningless data.
log "verifying providers on the running pod"
args=$(kubectl -n "$TRAEFIK_NS" get pod -l app.kubernetes.io/name=traefik \
  -o jsonpath='{.items[0].spec.containers[0].args}' 2>/dev/null || true)
case "$args" in
  *--providers.kubernetesingress*) log "  kubernetesingress provider: ENABLED" ;;
  *) die "kubernetesingress provider not enabled on the running pod (args: $args)" ;;
esac
case "$args" in
  *--providers.kubernetescrd*) log "  kubernetescrd provider: ENABLED" ;;
  *) die "kubernetescrd provider not enabled on the running pod (args: $args)" ;;
esac

# Sanity: confirm the rolled-out Deployment template carries the requested
# tag. We deliberately query the Deployment (not a pod) because with
# replicas>1 there's a race window after rollout-status where old
# Terminating pods are still in the API; `kubectl get pod` returns them in
# creationTimestamp order so .items[0] picks the *oldest* (still-on-old-tag)
# pod and produces a misleading warning.
deploy_image=$(kubectl -n "$TRAEFIK_NS" get deploy traefik \
  -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)
log "Traefik Deployment image: $deploy_image"
case "$deploy_image" in
  *":$VERSION") ;;
  *) log "WARN: Deployment image does not end with :$VERSION — verify before trusting capture" ;;
esac
