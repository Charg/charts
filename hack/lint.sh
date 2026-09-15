#!/usr/bin/env bash
# chart-testing lint + yamllint + kubeconform over rendered manifests.

source "$(dirname "${BASH_SOURCE[0]}")/tools.sh"

require_tools ct helm yamllint kubeconform yamale

cd "${REPO_ROOT}"

echo "==> yamllint"
yamllint --strict .

echo "==> ct lint"
# ct diffs against the target branch; on a detached or shallow checkout it has
# nothing to compare and lints nothing, which is the correct trivial pass.
ct_etc="$(ct_config_dir)"
ct lint --config ct.yaml \
  --chart-yaml-schema "${ct_etc}/chart_schema.yaml" \
  --lint-conf "${ct_etc}/lintconf.yaml"

echo "==> kubeconform"
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

while IFS= read -r chart; do
  echo "--> ${chart#"${REPO_ROOT}/"}"
  value_files=("${chart}/values.yaml")
  while IFS= read -r ci_values; do
    value_files+=("${ci_values}")
  done < <(find "${chart}/ci" -maxdepth 1 -name '*-values.yaml' 2>/dev/null | sort)

  for values in "${value_files[@]}"; do
    echo "    values: $(basename "${values}")"
    helm template lint-release "${chart}" --values "${values}" |
      kubeconform "${kubeconform_args[@]}"
  done
done <<<"${charts}"
