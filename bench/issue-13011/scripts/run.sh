#!/usr/bin/env bash
# End-to-end driver: setup → install Traefik 3.0.4 → deploy workload → capture
# → upgrade to latest 3.1.x → capture → upgrade to latest 3.6.x → capture
# → summarize.
#
# Env overrides:
#   CAPTURE_SAMPLES  default 60. Samples to capture per version (15s cadence,
#                    so 60 ≈ 15 min wall-clock). Set lower (e.g. 8) for a
#                    smoke test of the harness itself.
#   V304             default v3.0.4. Override the baseline version.
#   V31              default empty (auto-resolve to latest 3.1.x).
#   V36              default empty (auto-resolve to latest 3.6.x).
set -euo pipefail
source "$(dirname "$0")/lib.sh"

require_cmd helm jq

CAPTURE_SAMPLES="${CAPTURE_SAMPLES:-60}"
V304="${V304:-v3.0.4}"

# Resolve "latest 3.X.Y" by querying the chart index. helm search with
# --versions lists every chart version newest-first; we filter by app_version
# matching the line we want and take the first hit.
resolve_latest() {
  local minor="$1"
  helm search repo traefik/traefik --versions --output json 2>/dev/null \
    | jq -r --arg pat "^v3\\.${minor}\\." '.[] | .app_version | select(test($pat))' \
    | head -1
}

# Refresh the chart index once up front so resolve_latest sees current data.
helm repo add traefik https://traefik.github.io/charts >/dev/null 2>&1 || true
helm repo update traefik >/dev/null

V31="${V31:-$(resolve_latest 1)}"
V36="${V36:-$(resolve_latest 6)}"
[[ -n "$V31" ]] || die "could not resolve latest v3.1.x — is helm repo updated?"
[[ -n "$V36" ]] || die "could not resolve latest v3.6.x — is helm repo updated?"

log "capture plan:"
log "  V304 = $V304"
log "  V31  = $V31"
log "  V36  = $V36"
log "  capture per version = ${CAPTURE_SAMPLES} samples"

mkdir -p "$RESULTS_DIR"

# Setup
"$(dirname "$0")/setup-cluster.sh"

# Install baseline + workload (workload persists across upgrades — same load
# applied to each version is the whole point).
"$(dirname "$0")/install-traefik.sh" "$V304"
"$(dirname "$0")/deploy-workload.sh"

run_capture() {
  local ver="$1"
  log "===== capture: $ver ====="
  "$(dirname "$0")/capture-cpu.sh" "$ver" "$CAPTURE_SAMPLES"
}

run_capture "$V304"

"$(dirname "$0")/install-traefik.sh" "$V31"
run_capture "$V31"

"$(dirname "$0")/install-traefik.sh" "$V36"
run_capture "$V36"

log "===== summary ====="
"$(dirname "$0")/summarize.sh"

log "done. CSVs and summary.txt in $RESULTS_DIR"
log "cluster '$CLUSTER_NAME' is still running. Run scripts/teardown.sh to delete it."
