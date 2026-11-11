#!/usr/bin/env bash
# Verifies the images the given charts (default: every chart) deploy, before they are tested or
# published:
#   - every image is pinned by digest, so what CI tested is byte-for-byte what users pull;
#   - every image built by Charg/containers carries a keyless cosign signature from that repo's
#     release workflow on main. Those are images this project vouches for, so an unsigned or
#     foreign-signed one is a supply-chain failure, not a warning.
# Third-party images (Docker Hub upstreams) mostly publish no signatures to check; their digest
# pin plus scan-images.sh is what covers them.

source "$(dirname "${BASH_SOURCE[0]}")/tools.sh"

require_tools helm yq cosign

OWN_IMAGE_PREFIX="ghcr.io/charg/containers/"
OWN_IMAGE_IDENTITY="https://github.com/Charg/containers/.github/workflows/release.yaml@refs/heads/main"

if [ "$#" -gt 0 ]; then
  charts="$(printf '%s\n' "$@")"
else
  charts="$(list_charts)"
fi

status=0
while IFS= read -r chart; do
  [ -z "${chart}" ] && continue
  echo "==> ${chart#"${REPO_ROOT}/"}"
  while IFS= read -r image; do
    case "${image}" in
      *@sha256:*) ;;
      *)
        echo "    FAIL ${image}: not pinned by digest" >&2
        status=1
        continue
        ;;
    esac
    case "${image}" in
      "${OWN_IMAGE_PREFIX}"*)
        if cosign verify \
          --certificate-identity "${OWN_IMAGE_IDENTITY}" \
          --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
          "${image}" >/dev/null 2>&1; then
          echo "    signed  ${image}"
        else
          echo "    FAIL ${image}: no valid signature from ${OWN_IMAGE_IDENTITY}" >&2
          status=1
        fi
        ;;
      *) echo "    pinned  ${image}" ;;
    esac
  done < <(chart_images "${chart}")
done <<<"${charts}"

exit "${status}"
