#!/usr/bin/env bash
# This repo's chart checks, on top of the helm-charts flavour's (hack/lint.d/helm-charts.sh):
# chart versions bumped for every chart changed against the target branch, a declared Pod Security
# level per chart, every rendered image pinned by digest, and a trivy misconfiguration scan of the
# manifests each ci/ scenario renders.

# shellcheck source=hack/tools.sh
source "$(dirname "${BASH_SOURCE[0]}")/../tools.sh"

require_tools ct helm yq trivy

cd "${REPO_ROOT}"

log "ct lint --check-version-increment (changed charts)"
# ct diffs against the target branch; on a detached or shallow checkout it has nothing to compare
# and lints nothing, which is the correct trivial pass.
ct_etc="$(ct_config_dir)"
ct lint --config ct.yaml --check-version-increment \
  --chart-yaml-schema "${ct_etc}/chart_schema.yaml" \
  --lint-conf "${ct_etc}/lintconf.yaml"

charts="$(list_charts)"
if [ -z "${charts}" ]; then
  exit 0
fi

log "pod security, image pins, trivy config"
render_dir="$(mktemp -d)"
trap 'rm -rf "${render_dir}"' EXIT

while IFS= read -r chart; do
  name="$(basename "${chart}")"
  printf -- '--> %s\n' "${chart#"${REPO_ROOT}/"}" >&2
  # Fails if the chart does not declare the Pod Security Standard it meets; e2e enforces it.
  printf '    pod security: %s\n' "$(chart_pod_security "${chart}")" >&2
  mkdir -p "${render_dir}/${name}"

  while IFS= read -r values; do
    helm template lint-release "${chart}" --values "${values}" >"${render_dir}/${name}/$(basename "${values}")"
  done < <(chart_value_files "${chart}")

  # Offline half of verify-images.sh: nothing a chart renders may float on a mutable tag.
  unpinned="$(chart_images "${chart}" | grep -v '@sha256:[0-9a-f]\{64\}$' || true)"
  if [ -n "${unpinned}" ]; then
    printf '    images not pinned by digest:\n' >&2
    while IFS= read -r image; do
      printf '      %s\n' "${image}" >&2
    done <<<"${unpinned}"
    exit 1
  fi

  # HIGH and CRITICAL only: the lower severities flag choices a chart makes deliberately (no
  # resource limits by default, a writable root filesystem an image needs). A chart that cannot
  # avoid a HIGH finding (an image that must start as root) accepts it, with the reason, in its
  # own .trivyignore.yaml, kept out of the packaged chart by .helmignore.
  trivy_args=(config --quiet --exit-code 1 --severity 'HIGH,CRITICAL')
  if [ -f "${chart}/.trivyignore.yaml" ]; then
    trivy_args+=(--ignorefile "${chart}/.trivyignore.yaml")
  fi
  trivy "${trivy_args[@]}" "${render_dir}/${name}"
done <<<"${charts}"
