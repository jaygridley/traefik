#!/usr/bin/env bash
# Deploy the workload: shared backend Deployment + ROUTE_COUNT (default 200)
# routes in the bench-workload namespace, applied in two phases so Traefik's
# informer cache contains every leaf before any consumer arrives:
#
#   phase 1 — Service + 3 Middlewares per route (manifests/workload-1.tmpl.yaml)
#   phase 2 — Ingress + TraefikService + IngressRoute per route
#             (manifests/workload-2.tmpl.yaml)
#
# Without this ordering Traefik logs spurious "middleware/service not found"
# errors during deploy.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

require_cmd kubectl awk

BATCH_SIZE=50

# Render a per-route template ROUTE_COUNT times, applying via `kubectl apply`
# in batches of BATCH_SIZE routes. The single-stream pipe lets the apiserver
# dedupe and is much faster than ROUTE_COUNT individual kubectl invocations.
render_and_apply() {
  local tmpl="$1" phase_label="$2"
  [[ -f "$tmpl" ]] || die "missing template $tmpl"

  local batch_file batch_idx=0 in_batch=0 i
  batch_file=$(mktemp)
  : > "$batch_file"

  for (( i = 1; i <= ROUTE_COUNT; i++ )); do
    awk -v idx="$i" '{ gsub(/__I__/, idx); print }' "$tmpl" >> "$batch_file"
    printf -- '---\n' >> "$batch_file"
    in_batch=$(( in_batch + 1 ))
    if (( in_batch >= BATCH_SIZE )); then
      kubectl apply -f "$batch_file" >/dev/null
      log "  $phase_label batch $batch_idx ($in_batch routes)"
      : > "$batch_file"
      in_batch=0
      batch_idx=$(( batch_idx + 1 ))
    fi
  done
  if (( in_batch > 0 )); then
    kubectl apply -f "$batch_file" >/dev/null
    log "  $phase_label batch $batch_idx ($in_batch routes)"
  fi
  rm -f "$batch_file"
}

log "ensuring namespace $WORKLOAD_NS exists"
kubectl get ns "$WORKLOAD_NS" >/dev/null 2>&1 \
  || kubectl create ns "$WORKLOAD_NS" >/dev/null

log "applying shared backend"
kubectl apply -f "$MANIFESTS_DIR/backend.yaml"

log "waiting for backend rollout"
kubectl -n "$WORKLOAD_NS" rollout status deploy/dummy-backend --timeout=120s

# ===== Phase 1: leaves (Services + Middlewares) =====
log "phase 1: applying Services + Middlewares ($ROUTE_COUNT routes)"
render_and_apply "$MANIFESTS_DIR/workload-1.tmpl.yaml" "phase1"

# Wait for the EndpointSlice controller to materialise EndpointSlices for all
# Services. This is a real signal that the Services exist cluster-wide; it
# also doubles as a budget for Traefik to ingest Middlewares (which are much
# smaller and faster to process than EndpointSlices).
log "waiting for EndpointSlices (>= $ROUTE_COUNT expected)"
deadline=$(( $(date +%s) + 120 ))
while :; do
  count=$(kubectl get endpointslices -n "$WORKLOAD_NS" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [[ "${count:-0}" -ge "$ROUTE_COUNT" ]]; then
    break
  fi
  if (( $(date +%s) > deadline )); then
    die "EndpointSlice count stuck at $count (expected >= $ROUTE_COUNT)"
  fi
  sleep 3
done

# Belt-and-braces: brief settle so Traefik flushes its rebuild queue from the
# Middleware/Service flood before phase 2 references those resources.
sleep 5

# ===== Phase 2: consumers (Ingresses + TraefikServices + IngressRoutes) =====
log "phase 2: applying Ingresses + TraefikServices + IngressRoutes ($ROUTE_COUNT routes)"
render_and_apply "$MANIFESTS_DIR/workload-2.tmpl.yaml" "phase2"

# Sanity-check object counts. A silent partial apply (e.g. a CRD missing from
# this Traefik release) would otherwise produce a confusing capture.
count_kind() { kubectl get "$1" -n "$WORKLOAD_NS" --no-headers 2>/dev/null | wc -l | tr -d ' '; }
ing_n=$(count_kind ingress)
ir_n=$(count_kind ingressroute.traefik.io)
ts_n=$(count_kind traefikservice.traefik.io)
mw_n=$(count_kind middleware.traefik.io)
svc_n=$(count_kind svc)
[[ "$ing_n" -ge "$ROUTE_COUNT" ]] || die "Ingress count $ing_n < $ROUTE_COUNT"
[[ "$ir_n"  -ge "$ROUTE_COUNT" ]] || die "IngressRoute count $ir_n < $ROUTE_COUNT"
[[ "$ts_n"  -ge "$ROUTE_COUNT" ]] || die "TraefikService count $ts_n < $ROUTE_COUNT"
[[ "$mw_n"  -ge $(( ROUTE_COUNT * 3 )) ]] || die "Middleware count $mw_n < $(( ROUTE_COUNT * 3 ))"
[[ "$svc_n" -ge "$ROUTE_COUNT" ]] || die "Service count $svc_n < $ROUTE_COUNT"

log "workload deployed: $ing_n Ingresses, $ir_n IngressRoutes, $ts_n TraefikServices, $mw_n Middlewares, $svc_n Services"
