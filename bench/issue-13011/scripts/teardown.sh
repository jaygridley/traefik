#!/usr/bin/env bash
# Delete the kind cluster. Results CSVs are kept on disk.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

require_cmd kind

if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  log "deleting kind cluster '$CLUSTER_NAME'"
  kind delete cluster --name "$CLUSTER_NAME"
else
  log "kind cluster '$CLUSTER_NAME' not present, nothing to do"
fi
