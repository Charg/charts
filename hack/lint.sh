#!/usr/bin/env bash
# chart-testing lint + yamllint + workflow linting, then kubeconform and a trivy misconfiguration
# scan over the rendered manifests of every ci/ scenario.

source "$(dirname "${BASH_SOURCE[0]}")/tools.sh"

require_tools ct helm yamllint kubeconform yamale yq trivy actionlint zizmor

cd "${REPO_ROOT}"

echo "==> yamllint"
yamllint --strict .

echo "==> actionlint"
actionlint

echo "==> zizmor"
# Offline: the online audits (known-vulnerable action versions, impostor commits) need a GitHub
# token and network; Renovate already keeps the pinned actions current. --pedantic stays off so
# findings are the ones that matter, and any finding fails the run.
zizmor --offline --min-severity low .github/workflows

echo "==> ct lint"
# ct diffs against the target branch; on a detached or shallow checkout it has
# nothing to compare and lints nothing, which is the correct trivial pass.
ct_etc="$(ct_config_dir)"
ct lint --config ct.yaml \
  --chart-yaml-schema "${ct_etc}/chart_schema.yaml" \
  --lint-conf "${ct_etc}/lintconf.yaml"

echo "==> kubeconform + trivy config"
charts="$(list_charts)"
if [ -z "${charts}" ]; then
  echo "no charts present; nothing to validate"
  exit 0
fi

kubeconform_args=(
  -strict
  -summary
  -ignore-missing-schemas
  -schema-location default
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
)

render_dir="$(mktemp -d)"
trap 'rm -rf "${render_dir}"' EXIT

while IFS= read -r chart; do
  name="$(basename "${chart}")"
  echo "--> ${chart#"${REPO_ROOT}/"}"
  # Fails if the chart does not declare the Pod Security Standard it meets; e2e enforces it.
  echo "    pod security: $(chart_pod_security "${chart}")"
  mkdir -p "${render_dir}/${name}"

  while IFS= read -r values; do
    echo "    values: $(basename "${values}")"
    helm template lint-release "${chart}" --values "${values}" >"${render_dir}/${name}/$(basename "${values}")"
    kubeconform "${kubeconform_args[@]}" <"${render_dir}/${name}/$(basename "${values}")"
  done < <(chart_value_files "${chart}")

  # Offline half of verify-images.sh: nothing a chart renders may float on a mutable tag.
  unpinned="$(chart_images "${chart}" | grep -v '@sha256:[0-9a-f]\{64\}$' || true)"
  if [ -n "${unpinned}" ]; then
    echo "    images not pinned by digest:" >&2
    printf '      %s\n' ${unpinned} >&2
    exit 1
  fi

  # HIGH and CRITICAL only: the lower severities flag choices a chart makes deliberately (no
  # resource limits by default, a writable root filesystem an image needs). A chart that cannot
  # avoid a HIGH finding (an image that must start as root) accepts it, with the reason, in its
  # own .trivyignore.yaml, kept out of the packaged chart by .helmignore.
  trivy_args=(config --quiet --exit-code 1 --severity HIGH,CRITICAL)
  if [ -f "${chart}/.trivyignore.yaml" ]; then
    trivy_args+=(--ignorefile "${chart}/.trivyignore.yaml")
  fi
  trivy "${trivy_args[@]}" "${render_dir}/${name}"
done <<<"${charts}"
