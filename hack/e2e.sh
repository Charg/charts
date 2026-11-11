#!/usr/bin/env bash
# Integration suite: installs every ci/ scenario and asserts the claims a test pod cannot see.
#
# Usage: e2e.sh [--changed] [--list] [chart-dir...]
#   (no charts)  every chart
#   chart-dir    only those charts
#   --changed    only the charts this branch changes, or every chart when files outside charts/
#                change too (see changed_charts in tools.sh)
#   --list       print the selected chart directories and exit, without touching a cluster

source "$(dirname "${BASH_SOURCE[0]}")/tools.sh"

changed=false
list=false
explicit=()
for arg in "$@"; do
  case "${arg}" in
    --changed) changed=true ;;
    --list) list=true ;;
    -*)
      echo "unknown option: ${arg}" >&2
      exit 2
      ;;
    *) explicit+=("$(cd "${arg}" && pwd)") ;;
  esac
done

if [ "${changed}" = true ] && [ "${#explicit[@]}" -gt 0 ]; then
  echo "--changed and explicit charts are mutually exclusive" >&2
  exit 2
fi

if [ "${changed}" = true ]; then
  require_tools ct git
  charts="$(changed_charts)"
elif [ "${#explicit[@]}" -gt 0 ]; then
  charts="$(printf '%s\n' "${explicit[@]}")"
else
  charts="$(list_charts)"
fi

if [ "${list}" = true ]; then
  [ -z "${charts}" ] || echo "${charts}"
  exit 0
fi

if [ -z "${charts}" ]; then
  echo "no charts selected; nothing to install"
  exit 0
fi

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
done <<<"${charts}"

# The HA assertions install technitium-dns-server; they say nothing about any other chart.
if grep -qx "${CHART_DIR}/technitium-dns-server" <<<"${charts}"; then
  echo "==> HA topology assertions"
  "${REPO_ROOT}/hack/ha-assert.sh"
fi
