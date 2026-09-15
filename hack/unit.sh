#!/usr/bin/env bash
# helm-unittest across every chart in the repo.

source "$(dirname "${BASH_SOURCE[0]}")/tools.sh"

require_tools helm

charts="$(list_charts)"
if [ -z "${charts}" ]; then
  echo "no charts present; nothing to test"
  exit 0
fi

status=0
while IFS= read -r chart; do
  # An unmatched glob stays literal, so testing the first expansion for existence detects
  # "no test files" without compgen, which the nixpkgs non-interactive bash does not ship.
  test_files=("${chart}"/tests/*_test.yaml)
  if [ ! -e "${test_files[0]}" ]; then
    echo "==> ${chart#"${REPO_ROOT}/"}: no unit tests"
    continue
  fi
  echo "==> ${chart#"${REPO_ROOT}/"}"
  helm unittest --strict --file 'tests/*_test.yaml' "${chart}" || status=1
done <<<"${charts}"

exit "${status}"
