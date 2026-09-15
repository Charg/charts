#!/usr/bin/env bash
# Integration suite: installs every ci/ scenario and asserts the claims a test pod cannot see.

source "$(dirname "${BASH_SOURCE[0]}")/tools.sh"

require_tools ct helm kubectl

cd "${REPO_ROOT}"

export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"
CONTEXT="kind-${KIND_CLUSTER_NAME}"

if ! kubectl --context "${CONTEXT}" get nodes >/dev/null 2>&1; then
  echo "no reachable cluster at context ${CONTEXT}; run 'just cluster-up' first" >&2
  exit 1
fi
kubectl config use-context "${CONTEXT}" >/dev/null

echo "==> ct lint-and-install"
# One lint, one install and one helm test run per ci/*-values.yaml, by chart-testing's own
# convention. Adding a scenario means adding a file and nothing else.
ct_etc="$(ct_config_dir)"
ct lint-and-install \
  --config ct.yaml \
  --all \
  --chart-yaml-schema "${ct_etc}/chart_schema.yaml" \
  --lint-conf "${ct_etc}/lintconf.yaml"

echo "==> HA topology assertions"
"${REPO_ROOT}/hack/ha-assert.sh"
