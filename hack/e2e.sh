#!/usr/bin/env bash
# Integration suite: installs every ci/ scenario and asserts the claims a test pod cannot see.

source "$(dirname "${BASH_SOURCE[0]}")/tools.sh"

require_tools ct helm kubectl yq

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
#
# Each chart installs into its own namespace that ENFORCES the Pod Security Standard the chart
# declares (charg.github.io/pod-security in Chart.yaml), and warns on anything short of
# restricted. A default or scenario that drifts below the declared level is then rejected by the
# API server here, rather than by a user's admission controller.
ct_etc="$(ct_config_dir)"
while IFS= read -r chart; do
  name="$(basename "${chart}")"
  level="$(chart_pod_security "${chart}")"
  namespace="e2e-${name}"
  echo "--> ${name}: pod security ${level}, namespace ${namespace}"

  kubectl delete namespace "${namespace}" --ignore-not-found --wait=true >/dev/null
  kubectl create namespace "${namespace}" >/dev/null
  kubectl label namespace "${namespace}" \
    "pod-security.kubernetes.io/enforce=${level}" \
    pod-security.kubernetes.io/enforce-version=latest \
    pod-security.kubernetes.io/warn=restricted \
    pod-security.kubernetes.io/warn-version=latest >/dev/null

  ct lint-and-install \
    --config ct.yaml \
    --charts "${chart}" \
    --namespace "${namespace}" \
    --release-label app.kubernetes.io/instance \
    --chart-yaml-schema "${ct_etc}/chart_schema.yaml" \
    --lint-conf "${ct_etc}/lintconf.yaml"

  kubectl delete namespace "${namespace}" --wait=false >/dev/null
done < <(list_charts)

echo "==> HA topology assertions"
"${REPO_ROOT}/hack/ha-assert.sh"
