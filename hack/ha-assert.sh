#!/usr/bin/env bash
# Asserts the HA claims from outside the cluster. A helm test pod runs inside the cluster and
# cannot observe scheduling or storage topology, so node spread and per-replica volumes have to
# be checked with kubectl.
#
# Counting DISTINCT node names is the point: it is the only assertion that catches anti-affinity
# silently regressing from required to preferred.

source "$(dirname "${BASH_SOURCE[0]}")/tools.sh"

require_tools helm kubectl

CHART="${CHART_DIR}/technitium-dns-server"
VALUES="${CHART}/ci/ha-values.yaml"
RELEASE="ha-assert"
NAMESPACE="ha-assert-$$"
CONTEXT="kind-${KIND_CLUSTER_NAME}"
KUBECTL=(kubectl --context "${CONTEXT}" --namespace "${NAMESPACE}")

EXPECTED_REPLICAS="$(awk '/^replicaCount:/ {print $2}' "${VALUES}")"
if [ -z "${EXPECTED_REPLICAS}" ]; then
  echo "could not read replicaCount from ${VALUES}" >&2
  exit 1
fi

cleanup() {
  helm uninstall "${RELEASE}" --namespace "${NAMESPACE}" --kube-context "${CONTEXT}" --wait >/dev/null 2>&1 || true
  kubectl --context "${CONTEXT}" delete namespace "${NAMESPACE}" --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

kubectl --context "${CONTEXT}" create namespace "${NAMESPACE}" >/dev/null

echo "--> installing ${EXPECTED_REPLICAS} replicas into ${NAMESPACE}"
helm install "${RELEASE}" "${CHART}" \
  --namespace "${NAMESPACE}" \
  --kube-context "${CONTEXT}" \
  --values "${VALUES}" \
  --wait \
  --timeout 10m >/dev/null

selector="app.kubernetes.io/instance=${RELEASE},app.kubernetes.io/name=technitium-dns-server"

pod_count="$("${KUBECTL[@]}" get pods --selector "${selector}" --no-headers | wc -l | tr -d ' ')"
if [ "${pod_count}" -ne "${EXPECTED_REPLICAS}" ]; then
  echo "FAIL: expected ${EXPECTED_REPLICAS} pods, found ${pod_count}" >&2
  exit 1
fi

distinct_nodes="$("${KUBECTL[@]}" get pods --selector "${selector}" \
  -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort -u | grep -c .)"
if [ "${distinct_nodes}" -ne "${EXPECTED_REPLICAS}" ]; then
  echo "FAIL: ${EXPECTED_REPLICAS} replicas occupy only ${distinct_nodes} distinct node(s)" >&2
  "${KUBECTL[@]}" get pods --selector "${selector}" -o wide >&2
  exit 1
fi
echo "PASS: ${EXPECTED_REPLICAS} replicas on ${distinct_nodes} distinct nodes"

bound_claims="$("${KUBECTL[@]}" get pvc --selector "${selector}" \
  -o jsonpath='{range .items[?(@.status.phase=="Bound")]}{.metadata.name}{"\n"}{end}' | sort -u | grep -c .)"
if [ "${bound_claims}" -ne "${EXPECTED_REPLICAS}" ]; then
  echo "FAIL: expected ${EXPECTED_REPLICAS} distinct Bound volume claims, found ${bound_claims}" >&2
  "${KUBECTL[@]}" get pvc --selector "${selector}" >&2
  exit 1
fi

distinct_volumes="$("${KUBECTL[@]}" get pvc --selector "${selector}" \
  -o jsonpath='{range .items[*]}{.spec.volumeName}{"\n"}{end}' | sort -u | grep -c .)"
if [ "${distinct_volumes}" -ne "${EXPECTED_REPLICAS}" ]; then
  echo "FAIL: ${EXPECTED_REPLICAS} claims share only ${distinct_volumes} distinct volume(s)" >&2
  exit 1
fi
echo "PASS: ${EXPECTED_REPLICAS} distinct Bound volume claims on ${distinct_volumes} distinct volumes"

per_replica_services="$("${KUBECTL[@]}" get svc --selector "${selector}" \
  -o jsonpath='{range .items[*]}{.spec.selector.statefulset\.kubernetes\.io/pod-name}{"\n"}{end}' |
  grep -c . || true)"
if [ "${per_replica_services}" -ne "${EXPECTED_REPLICAS}" ]; then
  echo "FAIL: expected ${EXPECTED_REPLICAS} per-replica Services, found ${per_replica_services}" >&2
  exit 1
fi
echo "PASS: ${EXPECTED_REPLICAS} per-replica Services each selecting a single pod"
