#!/usr/bin/env bash
# Install or upgrade Traefik to a specific image tag (e.g. v3.0.4, v3.1.7, v3.6.2).
# Usage: install-traefik.sh <image-tag> [chart-version]
#
# The optional chart-version pins the traefik/traefik Helm chart via
# `helm --version`. Required for older image tags now that the latest chart
# floors at Traefik v3.6.0+. Omit to use the chart-repo's latest (correct for
# locally-built master/v3.7-dev images).
set -euo pipefail
source "$(dirname "$0")/lib.sh"

require_cmd helm kubectl

VERSION="${1:?usage: install-traefik.sh <image-tag, e.g. v3.0.4> [chart-version]}"
CHART_VERSION="${2:-}"

# Local-image mode: when TRAEFIK_LOCAL_IMAGE=1, the requested tag refers to
# an image that lives in the host's Docker daemon (produced by
# `make build-image-dirty` as `traefik/traefik:latest`, then aliased to
# `traefik/traefik:$VERSION` — see run.sh pre-flight). We load it into the
# kind cluster's nodes and pin pullPolicy=Never so kubelet doesn't try to
# pull from Docker Hub.
#
# We also override `image.registry=localhost` + `image.repository=
# traefik/traefik`. Two reasons:
#   1. The chart's `image.repository=traefik` default would make the pod
#      reference `docker.io/traefik:$VERSION` — a single-segment Docker
#      Hub path whose containerd lookup does not consistently match the
#      kind-loaded image. The two-segment `traefik/traefik` side-steps
#      that ambiguity.
#   2. Kind's `ctr images import` (containerd 2.0+, kind v0.30+) prefixes
#      unqualified refs with `localhost/` rather than `docker.io/`, so on
#      the nodes the image actually lives at
#      `localhost/traefik/traefik:$VERSION`. Pointing the chart at
#      `localhost` makes kubelet's lookup match what's in containerd.
local_image_install_flags=()
if [[ "${TRAEFIK_LOCAL_IMAGE:-}" == "1" ]]; then
  require_cmd kind docker
  if ! docker image inspect "traefik/traefik:$VERSION" >/dev/null 2>&1; then
    die "local image traefik/traefik:$VERSION not present in Docker daemon; build with 'make build-image-dirty' from the repo root (produces traefik/traefik:latest) and tag it as 'traefik/traefik:$VERSION'"
  fi
  log "local-image mode: loading traefik/traefik:$VERSION into kind cluster '$CLUSTER_NAME'"
  kind load docker-image "traefik/traefik:$VERSION" --name "$CLUSTER_NAME"
  local_image_install_flags=(
    --set "image.registry=localhost"
    --set "image.repository=traefik/traefik"
    --set "image.pullPolicy=Never"
  )
fi

# Idempotent. helm repo add returns non-zero if already added on some helm
# versions; ignore it.
helm repo add traefik https://traefik.github.io/charts >/dev/null 2>&1 || true
helm repo update traefik >/dev/null

chart_version_flag=()
if [[ -n "$CHART_VERSION" ]]; then
  chart_version_flag=(--version "$CHART_VERSION")
fi

log "installing/upgrading Traefik with image.tag=$VERSION chart=${CHART_VERSION:-<latest>} replicas=$TRAEFIK_REPLICAS"
# Notes on the flags:
#  - image.tag overrides the chart's bundled appVersion; CHART_VERSION pins
#    the chart itself so older image tags get a chart that still supports
#    them (the current latest chart floors at Traefik v3.6.0+).
#  - Both providers enabled because the issue affects both kubernetes and
#    kubernetescrd; we use Ingress here but the CRD provider must be on so the
#    `Middleware` annotation lookup resolves.
#  - resources.* unset (helm default) — we measure CPU absolute, not throttled.
#  - logs at ERROR to keep capture-time noise down.
#  - API debug/insecure to support the Go profiler's scrape of the /debug/pprof endpoints
helm upgrade --install traefik traefik/traefik \
  ${chart_version_flag[@]+"${chart_version_flag[@]}"} \
  --namespace "$TRAEFIK_NS" --create-namespace \
  --set "image.tag=$VERSION" \
  --set "deployment.replicas=$TRAEFIK_REPLICAS" \
  --set providers.kubernetesIngress.enabled=true \
  --set providers.kubernetesCRD.enabled=true \
  --set ingressClass.enabled=true \
  --set ingressClass.isDefaultClass=true \
  --set service.type=ClusterIP \
  --set "additionalArguments={--api.debug=true,--api.insecure=true}" \
  --set "env[0].name=GOMEMLIMIT" \
  --set "env[0].value=400MiB" \
  ${local_image_install_flags[@]+"${local_image_install_flags[@]}"} \
  --wait --timeout "$INSTALL_TIMEOUT"

log "waiting for Traefik rollout"
kubectl -n "$TRAEFIK_NS" rollout status deploy/traefik --timeout="$INSTALL_TIMEOUT"

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
