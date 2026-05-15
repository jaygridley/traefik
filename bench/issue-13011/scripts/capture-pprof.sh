#!/usr/bin/env bash
# Snapshot pprof profiles (heap with forced GC, goroutine, allocs, optional CPU)
# from a running Traefik pod and save them into results/<profile>-<label>.pb.gz.
#
# `heap?gc=1` forces a GC immediately before the snapshot, which is the only
# way to isolate live heap from unreclaimed Go heap slack — kubectl-top sees
# slack, pprof-without-gc-flag includes it too. The whole point of this script
# is to settle whether a kubectl-top memory delta reflects live heap or runtime
# slack, so the forced-GC variant is non-negotiable for the heap profile.
#
# Requires `api.insecure=true` and `api.debug=true` on the Traefik install
# (install-traefik.sh already sets both). The API listens on the "traefik"
# entryPoint, which the Helm chart binds to containerPort 9000.
#
# Usage:
#   capture-pprof.sh <label> [duration_seconds]
#
# If duration_seconds is given, also captures a CPU profile of that length.
# The pprof CPU endpoint blocks for the full window, so set this to e.g. 30
# during a steady-state capture, not in front of an actual benchmark.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

require_cmd kubectl curl

LABEL="${1:?usage: capture-pprof.sh <label> [duration_seconds]}"
DURATION="${2:-0}"
PPROF_PORT="${PPROF_PORT:-8080}"

mkdir -p "$RESULTS_DIR"

# Pick the first running Traefik pod. With replicas>1 we'd want every pod,
# but the bench harness pins TRAEFIK_REPLICAS=1 by default, and even with
# more replicas heap-vs-heap comparison only needs a representative pod.
pod=$(kubectl -n "$TRAEFIK_NS" get pod -l app.kubernetes.io/name=traefik \
        --field-selector=status.phase=Running -o name 2>/dev/null | head -1 || true)
[[ -n "$pod" ]] || die "no running Traefik pod found in namespace $TRAEFIK_NS"
log "target: $pod (port $PPROF_PORT)"

# Use an ephemeral local port to avoid colliding with anything the user has
# already port-forwarded. /dev/tcp gives us a free port without needing `ss`
# or `nc` — bind, read the port, release.
local_port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()' 2>/dev/null || true)
if [[ -z "$local_port" ]]; then
  # python3 not on PATH — fall back to the same port number and accept the risk.
  local_port="$PPROF_PORT"
fi

log "port-forwarding $pod $local_port:$PPROF_PORT"
kubectl -n "$TRAEFIK_NS" port-forward "$pod" "$local_port:$PPROF_PORT" >/dev/null 2>&1 &
pf_pid=$!
cleanup() {
  kill "$pf_pid" 2>/dev/null || true
  wait "$pf_pid" 2>/dev/null || true
}
trap cleanup EXIT

# Wait for the forwarder to start accepting connections. Poll instead of a
# blind sleep so the script doesn't pad runtime when the forwarder is fast,
# and surfaces a clear error when it's stuck.
for _ in $(seq 1 30); do
  if curl -fsS -o /dev/null --max-time 1 "http://127.0.0.1:$local_port/debug/pprof/" 2>/dev/null; then
    break
  fi
  sleep 0.5
done
if ! curl -fsS -o /dev/null --max-time 1 "http://127.0.0.1:$local_port/debug/pprof/"; then
  die "port-forward to $pod:$PPROF_PORT not responding on 127.0.0.1:$local_port; is api.insecure=true on the install?"
fi

fetch() {
  local name="$1" path="$2"
  local out="$RESULTS_DIR/${name}-${LABEL}.pb.gz"
  log "  $name -> $out"
  if ! curl -fsS -o "$out" "http://127.0.0.1:$local_port/debug/pprof/$path"; then
    die "failed to fetch $path"
  fi
}

# heap?gc=1: force GC before the dump, so the profile reflects *live* heap and
# not GC slack. Without this, a Go process with low alloc churn (the post-
# optimization case) looks heavier than it really is.
fetch heap      "heap?gc=1"
fetch goroutine "goroutine"
fetch allocs    "allocs"

if (( DURATION > 0 )); then
  log "  cpu profile (${DURATION}s window)"
  fetch profile "profile?seconds=$DURATION"
fi

log "done. Diff against another label with:"
log "  go tool pprof -base $RESULTS_DIR/heap-<base>.pb.gz $RESULTS_DIR/heap-${LABEL}.pb.gz"
log "  go tool pprof -top -cum $RESULTS_DIR/heap-${LABEL}.pb.gz | head -30"
