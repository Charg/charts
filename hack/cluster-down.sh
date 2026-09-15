#!/usr/bin/env bash
# Deletes the kind cluster. Safe to run when no cluster exists.

source "$(dirname "${BASH_SOURCE[0]}")/tools.sh"

require_tools kind

if kind get clusters 2>/dev/null | grep -qx "${KIND_CLUSTER_NAME}"; then
  kind delete cluster --name "${KIND_CLUSTER_NAME}"
else
  echo "cluster ${KIND_CLUSTER_NAME} does not exist"
fi
