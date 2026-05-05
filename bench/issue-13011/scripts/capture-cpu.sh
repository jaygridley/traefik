#!/usr/bin/env bash
# Sample sum of Traefik pod CPU/memory across all replicas via metrics-server
# every 15s until N successful samples have been recorded, writing CSV to
# results/<label>.csv. cpu_m / mem_mi are *summed* across pods, not per-pod —
# we want the total CPU footprint of "Traefik" as a logical unit regardless of
# how many replicas the Deployment runs ($TRAEFIK_REPLICAS). pod_count is
# recorded so a brief replica restart during the window is visible in the data.
# Usage: capture-cpu.sh <label> <samples>
set -euo pipefail
source "$(dirname "$0")/lib.sh"

require_cmd kubectl

LABEL="${1:?usage: capture-cpu.sh <label> <samples>}"
SAMPLES="${2:?usage: capture-cpu.sh <label> <samples>}"

mkdir -p "$RESULTS_DIR"
OUT="$RESULTS_DIR/${LABEL}.csv"

# Pods are resolved by label selector on every tick (not pinned to a name up
# front), so a Traefik pod restart mid-capture doesn't strand the loop on a
# stale pod name. metrics-server stderr is captured via this tmpfile so the
# WARN log can surface the real reason for a failed sample.
err_file=$(mktemp)

# Start churn before the warmup so the loop is already steady-state by the
# time sampling begins. Cleanup is best-effort: capture failures should
# surface the original error, not a kubectl cleanup failure.
churn_pid=
cleanup_churn() {
  if [[ -n "$churn_pid" ]]; then
    kill "$churn_pid" 2>/dev/null || true
    wait "$churn_pid" 2>/dev/null || true
  fi
  kubectl -n "$WORKLOAD_NS" scale deploy/dummy-backend --replicas=2 \
    >/dev/null 2>&1 || true
  kubectl label nodes --all bench-churn- >/dev/null 2>&1 || true
  rm -f "$err_file"
}
trap cleanup_churn EXIT

if [[ "${CHURN_ENABLE:-0}" == "1" ]]; then
  log "starting churn (node=${CHURN_NODE_INTERVAL}s, eps=${CHURN_EPS_INTERVAL}s)"
  "$(dirname "$0")/churn.sh" &
  churn_pid=$!
else
  log "churn disabled (CHURN_ENABLE=0)"
fi

# 60s warmup so the post-upgrade config-load spike is excluded from the sample
# window. The issue under test is steady-state CPU.
log "warmup: 60s"
sleep 60

log "writing CSV to $OUT"
echo "timestamp,cpu_m,mem_mi,pod_count" > "$OUT"

# `kubectl top pod -l ... --no-headers` prints one line per pod, e.g.:
#     traefik-abc123 12m 45Mi
#     traefik-def456 13m 47Mi
# awk strips the unit suffixes and sums the columns; pod_count comes from NR.
# An empty stdout (selector matched nothing, or metrics-server hasn't
# scraped yet) yields "0 0 0" and is treated as a retry below.
sample_count=0
attempts=0
# Safety cap so a stuck metrics-server can't hang the harness indefinitely.
# Without a time-bounded loop, infinite retries become a real risk.
max_attempts=$(( SAMPLES * 5 ))

while (( sample_count < SAMPLES )); do
  if (( attempts >= max_attempts )); then
    die "exceeded $max_attempts attempts; captured only $sample_count/$SAMPLES samples"
  fi
  attempts=$(( attempts + 1 ))
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  if out=$(kubectl -n "$TRAEFIK_NS" top pod \
        -l app.kubernetes.io/name=traefik --no-headers 2>"$err_file"); then
    read -r cpu_m mem_mi pod_count < <(printf '%s\n' "$out" | awk '
        NF >= 3 {
          c=$2; m=$3
          sub(/m$/,"",c); sub(/Mi$/,"",m)
          cpu+=c; mem+=m; n++
        }
        END { printf "%d %d %d\n", cpu+0, mem+0, n+0 }')
    if (( pod_count == 0 )); then
      log "WARN: no Traefik pods reported by metrics-server at $ts (will retry next tick)"
    elif [[ "$cpu_m" =~ ^[0-9]+$ && "$mem_mi" =~ ^[0-9]+$ ]]; then
      if (( pod_count < TRAEFIK_REPLICAS )); then
        log "WARN: pod_count=$pod_count (expected $TRAEFIK_REPLICAS) at $ts — pod likely restarting"
      fi
      echo "$ts,$cpu_m,$mem_mi,$pod_count" >> "$OUT"
      sample_count=$(( sample_count + 1 ))
    else
      log "WARN: unparseable sample at $ts: $out"
    fi
  else
    err=$(<"$err_file")
    log "WARN: kubectl top failed at $ts: ${err:-<no stderr>} (will retry next tick)"
  fi
  if (( sample_count < SAMPLES )); then
    sleep 15
  fi
done

log "captured $sample_count samples to $OUT"
