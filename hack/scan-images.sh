#!/usr/bin/env bash
# CVE-scans the images the given charts (default: every chart; --changed: only the charts that
# differ from the target branch, as chart-testing sees it) deploy with trivy, failing on a
# CRITICAL vulnerability that has a fix available. Unfixed ones are reported by the summary
# table but do not fail: nothing in this repo can act on them except waiting for upstream.
#
# A chart accepts a specific finding, with the reason and an expiry, in its own
# .trivyignore.yaml (the same file the misconfiguration scan in lint.sh reads).

source "$(dirname "${BASH_SOURCE[0]}")/tools.sh"

require_tools helm yq trivy

if [ "${1:-}" = "--changed" ]; then
  # A PR is gated on the images it changes, not on every upstream CVE published since the last
  # one: an unrelated fix must not be blocked by an image it never touched.
  require_tools ct
  charts="$(cd "${REPO_ROOT}" && ct list-changed --config ct.yaml | sed "s|^|${REPO_ROOT}/|")"
  if [ -z "${charts}" ]; then
    echo "no charts changed; nothing to scan"
    exit 0
  fi
elif [ "$#" -gt 0 ]; then
  charts="$(printf '%s\n' "$@")"
else
  charts="$(list_charts)"
fi

status=0
while IFS= read -r chart; do
  [ -z "${chart}" ] && continue
  echo "==> ${chart#"${REPO_ROOT}/"}"
  trivy_args=(image --quiet --scanners vuln --ignore-unfixed --severity CRITICAL --exit-code 1)
  if [ -f "${chart}/.trivyignore.yaml" ]; then
    trivy_args+=(--ignorefile "${chart}/.trivyignore.yaml")
  fi
  while IFS= read -r image; do
    echo "--> ${image}"
    trivy "${trivy_args[@]}" "${image}" || status=1
  done < <(chart_images "${chart}")
done <<<"${charts}"

exit "${status}"
