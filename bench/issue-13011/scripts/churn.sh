#!/usr/bin/env bash
# Generate Node and EndpointSlice update events during the capture window so
# Traefik's informer cache is not idle. Issue #13011 is event-volume-driven;
# without churn the harness only sees passive kubelet heartbeats and the
# regression signal stays in the noise floor.
#
# Two independent loops in their own subshells:
#   - Node:          flip a `bench-churn=A|B` label on every worker node
#                    every CHURN_NODE_INTERVAL seconds.
#   - EndpointSlice: scale `dummy-backend` between 2↔3 replicas every
#                    CHURN_EPS_INTERVAL seconds. All 200 svc-N Services
#                    select app=dummy-backend, so each scale fans out to
#                    200 EndpointSlice updates.
#
# capture-cpu.sh starts this in the background and kills it on EXIT, so we
# don't need our own SIGTERM handler beyond a trap that takes the subshells
# down with us.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

require_cmd kubectl

log "churn: node every ${CHURN_NODE_INTERVAL}s, eps every ${CHURN_EPS_INTERVAL}s"

(
  toggle=A
  while :; do
    kubectl label nodes -l '!node-role.kubernetes.io/control-plane' \
      "bench-churn=$toggle" --overwrite >/dev/null 2>&1 || true
    if [[ $toggle == A ]]; then toggle=B; else toggle=A; fi
    sleep "$CHURN_NODE_INTERVAL"
  done
) &
node_pid=$!

(
  replicas=3
  while :; do
    kubectl -n "$WORKLOAD_NS" scale deploy/dummy-backend \
      --replicas="$replicas" >/dev/null 2>&1 || true
    if [[ $replicas == 3 ]]; then replicas=2; else replicas=3; fi
    sleep "$CHURN_EPS_INTERVAL"
  done
) &
eps_pid=$!

trap 'kill $node_pid $eps_pid 2>/dev/null || true' EXIT TERM INT
wait
