#!/usr/bin/env bash
# End-to-end driver: setup → install Traefik 3.0.4 → deploy workload → capture
# → upgrade to latest 3.1.x → capture → upgrade to latest 3.6.x → capture
# → upgrade to locally-built image → capture → summarize.
#
# Env overrides:
#   CAPTURE_SAMPLES     default 60. Samples to capture per version (15s cadence,
#                       so 60 ≈ 15 min wall-clock). Set lower (e.g. 8) for a
#                       smoke test of the harness itself.
#   V304                default v3.0.4. Override the baseline version.
#   V31                 default empty (auto-resolve to latest 3.1.x).
#   V36                 default empty (auto-resolve to latest 3.6.x).
#   CHART304/CHART31/CHART36
#                       default empty (auto-resolve to the chart whose
#                       appVersion matches V304/V31/V36). The latest
#                       traefik/traefik chart floors at Traefik v3.6.0+, so
#                       older image tags must install on an older chart.
#   VLOCAL              default `v3.7.1-dev`. SemVer alias for the locally-built
#                       image (built as `traefik/traefik:latest` by
#                       `make build-image-dirty` from the repo root). The
#                       traefik/traefik Helm chart's role.yaml rejects
#                       non-SemVer tags like `latest`, so the harness aliases
#                       the build artifact to this tag before kind-loading.
#   SKIP_LOCAL_CAPTURE  default empty. Set to 1 to skip the local-image capture.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

require_cmd helm jq

CAPTURE_SAMPLES="${CAPTURE_SAMPLES:-60}"
V304="${V304:-v3.0.4}"
VLOCAL="${VLOCAL:-v3.7.1-dev}"

# Resolve "latest 3.X.Y" by querying the chart index. helm search with
# --versions lists every chart version newest-first; we filter by app_version
# matching the line we want and take the first hit.
resolve_latest() {
  local minor="$1"
  helm search repo traefik/traefik --versions --output json 2>/dev/null \
    | jq -r --arg pat "^v3\\.${minor}\\." '.[] | .app_version | select(test($pat))' \
    | head -1
}

# Given an app_version like "v3.0.4", return the highest chart version whose
# appVersion equals that tag. Same query shape as resolve_latest — just a
# different jq projection. Needed because the latest traefik/traefik chart no
# longer supports image tags below v3.6.0, so each tag must install on a
# chart that still bundled it.
resolve_chart_for_app() {
  local app_ver="$1"
  helm search repo traefik/traefik --versions --output json 2>/dev/null \
    | jq -r --arg av "$app_ver" '.[] | select(.app_version == $av) | .version' \
    | head -1
}

# Refresh the chart index once up front so resolvers see current data.
helm repo add traefik https://traefik.github.io/charts >/dev/null 2>&1 || true
helm repo update traefik >/dev/null

V31="${V31:-$(resolve_latest 1)}"
V36="${V36:-$(resolve_latest 6)}"
[[ -n "$V31" ]] || die "could not resolve latest v3.1.x — is helm repo updated?"
[[ -n "$V36" ]] || die "could not resolve latest v3.6.x — is helm repo updated?"

CHART304="${CHART304:-$(resolve_chart_for_app "$V304")}"
CHART31="${CHART31:-$(resolve_chart_for_app "$V31")}"
CHART36="${CHART36:-$(resolve_chart_for_app "$V36")}"
[[ -n "$CHART304" ]] || die "no chart with appVersion=$V304 in traefik/traefik repo — pin CHART304 explicitly"
[[ -n "$CHART31" ]]  || die "no chart with appVersion=$V31 in traefik/traefik repo — pin CHART31 explicitly"
[[ -n "$CHART36" ]]  || die "no chart with appVersion=$V36 in traefik/traefik repo — pin CHART36 explicitly"

# Pre-flight the local image *before* spinning up the kind cluster — a missing
# image found 45+ minutes into the run is a waste of capture time.
#
# `make build-image-dirty` produces `traefik/traefik:latest`. We alias it to
# `traefik/traefik:$VLOCAL` (SemVer) so the chart's role.yaml accepts the
# tag. install-traefik.sh's local mode then kind-loads under that two-
# segment path and overrides image.repository accordingly — see the comment
# block there for why the two-segment path matters.
#
# Compare image IDs (not just existence) so a rebuild that updates :latest
# also refreshes the alias — otherwise the second run silently benches the
# previous binary.
local_image_short_id=""
if [[ -z "${SKIP_LOCAL_CAPTURE:-}" ]]; then
  require_cmd docker
  if ! docker image inspect "traefik/traefik:latest" >/dev/null 2>&1; then
    die "local image traefik/traefik:latest not present in Docker daemon; build it with 'make build-image-dirty' from the repo root, or set SKIP_LOCAL_CAPTURE=1 to skip the local capture"
  fi
  src_id=$(docker image inspect --format '{{.Id}}' "traefik/traefik:latest")
  dst_id=$(docker image inspect --format '{{.Id}}' "traefik/traefik:$VLOCAL" 2>/dev/null || true)
  if [[ "$src_id" != "$dst_id" ]]; then
    log "aliasing traefik/traefik:latest as traefik/traefik:$VLOCAL (SemVer tag accepted by chart's role.yaml)"
    docker tag "traefik/traefik:latest" "traefik/traefik:$VLOCAL"
  fi
  local_image_short_id="${src_id:0:19}"
fi

log "capture plan:"
log "  V304   = $V304 (chart $CHART304)"
log "  V31    = $V31 (chart $CHART31)"
log "  V36    = $V36 (chart $CHART36)"
if [[ -z "${SKIP_LOCAL_CAPTURE:-}" ]]; then
  log "  VLOCAL = $VLOCAL (locally-built $local_image_short_id, chart <latest>)"
else
  log "  VLOCAL = (skipped via SKIP_LOCAL_CAPTURE)"
fi
log "  capture per version = ${CAPTURE_SAMPLES} samples"

mkdir -p "$RESULTS_DIR"

# Setup
"$(dirname "$0")/setup-cluster.sh"

# Install baseline + workload (workload persists across upgrades — same load
# applied to each version is the whole point).
"$(dirname "$0")/install-traefik.sh" "$V304" "$CHART304"
"$(dirname "$0")/deploy-workload.sh"

run_capture() {
  local ver="$1"
  log "===== capture: $ver ====="
  "$(dirname "$0")/capture-cpu.sh" "$ver" "$CAPTURE_SAMPLES"
}

run_capture "$V304"

"$(dirname "$0")/install-traefik.sh" "$V31" "$CHART31"
run_capture "$V31"

"$(dirname "$0")/install-traefik.sh" "$V36" "$CHART36"
run_capture "$V36"

if [[ -z "${SKIP_LOCAL_CAPTURE:-}" ]]; then
  TRAEFIK_LOCAL_IMAGE=1 "$(dirname "$0")/install-traefik.sh" "$VLOCAL" "$CHART36"
  run_capture "$VLOCAL"
fi

log "===== summary ====="
"$(dirname "$0")/summarize.sh"

log "done. CSVs and summary.txt in $RESULTS_DIR"
log "cluster '$CLUSTER_NAME' is still running. Run scripts/teardown.sh to delete it."
