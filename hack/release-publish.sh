#!/usr/bin/env bash
# Packages, pushes, signs and verifies one chart as an OCI artifact, and attests the list of
# images it deploys. Assumes the caller has already logged in to ghcr.io (`helm registry login`)
# and, for signing, is running with a GitHub Actions OIDC token available (id-token: write);
# cosign picks that up ambiently.

source "$(dirname "${BASH_SOURCE[0]}")/tools.sh"

require_tools helm cosign jq yq

if [ "$#" -ne 1 ]; then
  echo "usage: $(basename "$0") <chart-path>" >&2
  exit 1
fi

CHART="$1"
[ -f "${CHART}/Chart.yaml" ] || {
  echo "${CHART}: no Chart.yaml" >&2
  exit 1
}

: "${GITHUB_REPOSITORY_OWNER:?GITHUB_REPOSITORY_OWNER must be set}"
: "${SIGNER_IDENTITY:?SIGNER_IDENTITY must be set (the certificate identity to verify against)}"

# GHCR rejects uppercase path segments; this repo's owner has one.
OWNER="$(printf '%s' "${GITHUB_REPOSITORY_OWNER}" | tr '[:upper:]' '[:lower:]')"
# Charts live under a charts/ path so they never collide with an image of the same name, which
# Charg/containers publishes under containers/.
NAMESPACE="${OWNER}/charts"

chart_field() {
  helm show chart "$1" | grep -E "^$2:" | head -1 | awk '{print $2}' | tr -d '"'"'"
}

NAME="$(chart_field "${CHART}" name)"
VERSION="$(chart_field "${CHART}" version)"
REF="ghcr.io/${NAMESPACE}/${NAME}"

echo "==> packaging ${NAME}-${VERSION}"
package_dir="$(mktemp -d)"
trap 'rm -rf "${package_dir}"' EXIT
helm package "${CHART}" --destination "${package_dir}"

echo "==> pushing to oci://ghcr.io/${NAMESPACE}"
# helm prints the resolved digest on push; that is the only identifier this script trusts. The
# tag it just pushed under is mutable, so a signature over the tag would assert nothing.
push_output="$(helm push "${package_dir}/${NAME}-${VERSION}.tgz" "oci://ghcr.io/${NAMESPACE}" 2>&1 | tee /dev/stderr)"
DIGEST="$(printf '%s\n' "${push_output}" | grep -oE 'sha256:[0-9a-f]{64}' | head -1)"

if [ -z "${DIGEST}" ]; then
  echo "could not parse a digest out of 'helm push' output; refusing to sign an unidentified artifact" >&2
  exit 1
fi

echo "==> signing ${REF}@${DIGEST} (keyless, OIDC)"
cosign sign --yes "${REF}@${DIGEST}"

echo "==> verifying ${REF}@${DIGEST}"
# A broken signing step must show up as a red build here, not as a consumer's problem weeks
# later, so verification happens in the same run against the identity this very workflow signs
# with. SIGNER_IDENTITY is the reusable publish workflow, not the workflow that called it: the
# certificate names the workflow file whose steps actually ran.
verify_args=(
  --certificate-identity "${SIGNER_IDENTITY}"
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com"
)
cosign verify "${verify_args[@]}" "${REF}@${DIGEST}" >/dev/null

echo "==> attesting the images ${NAME}-${VERSION} deploys"
# The images every ci/ scenario renders, helm test hooks included, each pinned by digest (lint
# refuses a chart that renders an unpinned one). An admission policy or an auditor can match a
# running image back to the signed chart version that put it there.
predicate="${package_dir}/images.json"
chart_images "${CHART}" | jq --raw-input . | jq --slurp \
  --arg chart "${NAME}" --arg version "${VERSION}" \
  '{chart: $chart, version: $version, images: .}' >"${predicate}"
cat "${predicate}"
cosign attest --yes --type "${IMAGES_PREDICATE_TYPE}" --predicate "${predicate}" "${REF}@${DIGEST}"
cosign verify-attestation "${verify_args[@]}" --type "${IMAGES_PREDICATE_TYPE}" \
  "${REF}@${DIGEST}" >/dev/null

echo "chart=${NAME} version=${VERSION} digest=${DIGEST} ref=${REF}"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "chart=${NAME}"
    echo "version=${VERSION}"
    echo "digest=${DIGEST}"
    echo "ref=${REF}"
  } >>"${GITHUB_OUTPUT}"
fi
