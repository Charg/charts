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

# Files that cannot change how any chart installs, so touching them alone does not widen the
# e2e selection to every chart. Anything else outside charts/ does.
E2E_NEUTRAL_PATHS='^(README\.md|LICENSE|\.github/renovate\.json5)$'

# Charts an integration run must cover for the changes on this branch, against the merge base
# with ct.yaml's target branch (committed, staged, unstaged and untracked changes alike):
#   - only files under charts/ changed: the charts ct list-changed reports;
#   - anything else changed (hack/, the flake, ct.yaml, workflows, the kind config, ...): every
#     chart, because shared tooling can break a chart whose own files are untouched.
# The reason for the choice goes to stderr; stdout is chart directories only, possibly empty.
changed_charts() {
  local base outside
  base="$(cd "${REPO_ROOT}" && git merge-base origin/main HEAD)" || {
    echo "cannot find a merge base with origin/main; fetch it, or run without --changed" >&2
    return 1
  }
  outside="$(
    cd "${REPO_ROOT}" &&
      { git diff --name-only "${base}"; git ls-files --others --exclude-standard; } |
      sort -u | grep -v '^charts/' | grep -Ev "${E2E_NEUTRAL_PATHS}" || true
  )"
  if [ -n "${outside}" ]; then
    {
      echo "files outside charts/ changed; selecting every chart:"
      echo "${outside}" | head -n 10 | sed 's/^/    /'
    } >&2
    list_charts
    return 0
  fi
  echo "nothing outside charts/ changed; selecting the charts ct list-changed reports" >&2
  (cd "${REPO_ROOT}" && ct list-changed --config ct.yaml) |
    while IFS= read -r chart; do
      # A deleted chart is listed as changed but has nothing left to install.
      if [ -f "${REPO_ROOT}/${chart}/Chart.yaml" ]; then echo "${REPO_ROOT}/${chart}"; fi
    done
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

# The ci/*-values.yaml scenarios of a chart, one per line, sorted. Falls back to values.yaml for
# a chart with no scenarios. A chart may require a value (anki-sync-server needs a user) and
# deliberately fail to render without it, which is why the bare defaults are not always usable.
chart_value_files() {
  local chart="$1" found
  found="$(find "${chart}/ci" -maxdepth 1 -name '*-values.yaml' 2>/dev/null | sort)"
  if [ -n "${found}" ]; then
    printf '%s\n' "${found}"
  else
    printf '%s\n' "${chart}/values.yaml"
  fi
}

# A top-level Chart.yaml annotation ($2) of a chart ($1), or nothing when it is absent.
chart_annotation() {
  helm show chart "$1" | yq ".annotations[\"$2\"] // \"\""
}

# The Pod Security Standard a chart declares its defaults meet (charg.github.io/pod-security).
# Fails when it is missing or not a known level, so a new chart cannot skip declaring one.
chart_pod_security() {
  local level
  level="$(chart_annotation "$1" charg.github.io/pod-security)"
  case "${level}" in
    restricted | baseline | privileged) echo "${level}" ;;
    *)
      echo "$1: Chart.yaml must set annotations.charg.github.io/pod-security to restricted," \
        "baseline or privileged (got '${level}')" >&2
      return 1
      ;;
  esac
}

# Every image a chart deploys across its ci/ scenarios, helm test hooks included, one per line,
# sorted and de-duplicated. Rendering every scenario rather than the bare defaults catches images
# that only appear behind a feature flag the scenarios turn on.
chart_images() {
  local chart="$1" values
  while IFS= read -r values; do
    helm template images-release "${chart}" --values "${values}"
    echo "---"
  done < <(chart_value_files "${chart}") |
    yq eval-all --no-doc \
      '.. | select(tag == "!!map") | select(has("image")) | .image | select(tag == "!!str")' - |
    sort -u
}

# in-toto predicate type of the attestation listing the images a published chart deploys.
IMAGES_PREDICATE_TYPE="https://charg.github.io/attestations/chart-images/v1"
