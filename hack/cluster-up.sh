#!/usr/bin/env bash
# Creates the throwaway kind cluster used by the integration suite.

source "$(dirname "${BASH_SOURCE[0]}")/tools.sh"

require_tools kind kubectl

if kind get clusters 2>/dev/null | grep -qx "${KIND_CLUSTER_NAME}"; then
  echo "cluster ${KIND_CLUSTER_NAME} already exists"
else
  kind create cluster \
    --name "${KIND_CLUSTER_NAME}" \
    --config "${REPO_ROOT}/hack/kind-cluster.yaml" \
    --wait 300s
fi

# kind's --wait only covers the control plane; workers go Ready once the CNI
# lands on them, which is after create returns.
kubectl --context "kind-${KIND_CLUSTER_NAME}" wait --for=condition=Ready nodes --all --timeout=300s
kubectl --context "kind-${KIND_CLUSTER_NAME}" get nodes
