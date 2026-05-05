# Shared helpers for bench/issue-13011 scripts. Sourced, never executed.
# shellcheck shell=bash

# Resolve repo-relative paths once. Callers source this file via:
#   source "$(dirname "$0")/lib.sh"
HARNESS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export HARNESS_ROOT
export MANIFESTS_DIR="${MANIFESTS_DIR:-$HARNESS_ROOT/manifests}"
export RESULTS_DIR="${RESULTS_DIR:-$HARNESS_ROOT/results}"

export CLUSTER_NAME="${CLUSTER_NAME:-traefik-bench}"
export TRAEFIK_NS="${TRAEFIK_NS:-traefik}"
export WORKLOAD_NS="${WORKLOAD_NS:-bench-workload}"
export ROUTE_COUNT="${ROUTE_COUNT:-200}"
export TRAEFIK_REPLICAS="${TRAEFIK_REPLICAS:-1}"

# Churn knobs — used by capture-cpu.sh / churn.sh to keep Node and
# EndpointSlice events flowing during the capture window.
export CHURN_ENABLE="${CHURN_ENABLE:-0}"
export CHURN_NODE_INTERVAL="${CHURN_NODE_INTERVAL:-15}"
export CHURN_EPS_INTERVAL="${CHURN_EPS_INTERVAL:-30}"

log()  { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die()  { log "ERROR: $*"; exit 1; }

require_cmd() {
  local missing=()
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    die "missing required commands: ${missing[*]}"
  fi
}
