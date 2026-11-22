#!/usr/bin/env bash
# helm-charts flavour, for every chart at charts/<name>/: chart-testing's lint (helm lint, Chart.yaml
# schema, yamllint of Chart.yaml and values), then kubeconform over the manifests each chart renders
# with values.yaml and with each ci/*-values.yaml.

# shellcheck source=hack/tools.sh
source "$(dirname "${BASH_SOURCE[0]}")/../tools.sh"

require_tools ct helm kubeconform yamale yamllint

cd "${REPO_ROOT}"

charts=()
for chart_yaml in charts/*/Chart.yaml; do
  [ -e "${chart_yaml}" ] && charts+=("$(dirname "${chart_yaml}")")
done
if ((${#charts[@]} == 0)); then
  exit 0
fi

# ct looks for its chart schema and lint config next to its binary, which nix doesn't give it.
ct_etc="$(cd "$(dirname "$(command -v ct)")/../etc/ct" && pwd)"

log "ct lint"
# --all: lint every chart, not only those changed against ct.yaml's target branch.
ct lint --config ct.yaml --all \
  --chart-yaml-schema "${ct_etc}/chart_schema.yaml" \
  --lint-conf "${ct_etc}/lintconf.yaml"

log "kubeconform"
kubeconform_args=(
  -strict
  -summary
  -ignore-missing-schemas
  -schema-location default
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
)
for chart in "${charts[@]}"; do
  for values in "${chart}/values.yaml" "${chart}"/ci/*-values.yaml; do
    [ -e "${values}" ] || continue
    printf '    %s\n' "${values}" >&2
    helm template lint "${chart}" --values "${values}" | kubeconform "${kubeconform_args[@]}"
  done
done
