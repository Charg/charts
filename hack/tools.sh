#!/usr/bin/env bash
# Shared shell setup sourced by every other script in hack/.
#
# Tool versions are no longer pinned here: the nix flake (flake.nix + flake.lock) is the single
# source of truth for the toolchain, and every script is expected to run inside its dev shell
# (`nix develop`, or `nix develop -c just <target>`). Bumping a tool is a flake.lock change.

set -euo pipefail

KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-charts-e2e}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHART_DIR="${REPO_ROOT}/charts"

# chart-testing does not discover its bundled lint config on its own; it lives next to the ct
# binary under ../etc/ct in the nix package. Resolve it from whichever ct is on PATH so a flake
# bump that moves the store path needs no edit here.
ct_config_dir() {
  local ct_bin
  ct_bin="$(command -v ct)" || {
    echo "ct not found on PATH; enter the dev shell with 'nix develop'" >&2
    return 1
  }
  cd "$(dirname "${ct_bin}")/../etc/ct" && pwd
}

# Charts present in the repo. Empty output is a valid state: the lint and unit
# targets must succeed on a checkout that has no charts yet.
list_charts() {
  [ -d "${CHART_DIR}" ] || return 0
  find "${CHART_DIR}" -mindepth 2 -maxdepth 2 -name Chart.yaml -print0 |
    xargs -0 -r -n1 dirname |
    sort
}

require_tools() {
  local missing=0 tool
  for tool in "$@"; do
    command -v "${tool}" >/dev/null 2>&1 || {
      echo "missing tool: ${tool}" >&2
      missing=1
    }
  done
  if [ "${missing}" -ne 0 ]; then
    echo "enter the dev shell first: 'nix develop' (or run the target as 'nix develop -c just <target>')" >&2
    return 1
  fi
}
