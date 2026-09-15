#!/usr/bin/env bash
# Packages, pushes, signs and verifies one chart as an OCI artifact. Assumes the caller has
# already logged in to ghcr.io (`helm registry login`) and, for signing, is running with a
# GitHub Actions OIDC token available (id-token: write); cosign picks that up ambiently.

source "$(dirname "${BASH_SOURCE[0]}")/tools.sh"

require_tools helm cosign

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
: "${GITHUB_WORKFLOW_REF:?GITHUB_WORKFLOW_REF must be set (used as the signer identity to verify against)}"

# GHCR rejects uppercase path segments; this repo's owner has one.
OWNER="$(printf '%s' "${GITHUB_REPOSITORY_OWNER}" | tr '[:upper:]' '[:lower:]')"

chart_field() {
  helm show chart "$1" | grep -E "^$2:" | head -1 | awk '{print $2}' | tr -d '"'"'"
}

NAME="$(chart_field "${CHART}" name)"
VERSION="$(chart_field "${CHART}" version)"
REF="ghcr.io/${OWNER}/${NAME}"

echo "==> packaging ${NAME}-${VERSION}"
package_dir="$(mktemp -d)"
trap 'rm -rf "${package_dir}"' EXIT
helm package "${CHART}" --destination "${package_dir}"

echo "==> pushing to oci://ghcr.io/${OWNER}"
# helm prints the resolved digest on push; that is the only identifier this script trusts. The
# tag it just pushed under is mutable, so a signature over the tag would assert nothing.
push_output="$(helm push "${package_dir}/${NAME}-${VERSION}.tgz" "oci://ghcr.io/${OWNER}" 2>&1 | tee /dev/stderr)"
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
# with.
cosign verify \
  --certificate-identity "https://github.com/${GITHUB_WORKFLOW_REF}" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
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
