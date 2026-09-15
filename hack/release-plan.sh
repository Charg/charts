#!/usr/bin/env bash
# Decides which charts need publishing by asking the registry, not by diffing git history: a
# push can bump several charts at once, and a re-run after a partial failure must reach the same
# answer without needing to know what the last run did.
#
# Fails closed on purpose. Re-pushing over a version consumers have already pinned is the one
# unrecoverable failure mode here, so anything short of a definitive "not found" from the
# registry (a permission error, a network blip, a 5xx) aborts the whole run instead of guessing.

source "$(dirname "${BASH_SOURCE[0]}")/tools.sh"

require_tools helm curl

: "${GITHUB_TOKEN:?GITHUB_TOKEN must be set (used to authenticate the registry query)}"
: "${GITHUB_ACTOR:?GITHUB_ACTOR must be set (used to authenticate the registry query)}"
: "${GITHUB_REPOSITORY_OWNER:?GITHUB_REPOSITORY_OWNER must be set}"

# GHCR rejects uppercase path segments; this repo's owner has one.
OWNER="$(printf '%s' "${GITHUB_REPOSITORY_OWNER}" | tr '[:upper:]' '[:lower:]')"

chart_field() {
  # $1 chart dir, $2 top-level Chart.yaml key. `helm show chart` normalizes the file, so a
  # simple start-of-line grep cannot be confused by a similarly-prefixed key (name vs appVersion).
  helm show chart "$1" | grep -E "^$2:" | head -1 | awk '{print $2}' | tr -d '"'"'"
}

# Resolves whether ${OWNER}/${2}:${3} already exists in GHCR. Prints exactly one of "missing" or
# "published" on success; on anything else it prints a message to stderr and exits non-zero,
# which the caller must NOT swallow inside a command substitution used as an if/case subject
# (that would run in a subshell and silently discard the abort). Assign to a plain variable
# first so `set -e` propagates the failure.
probe_registry() {
  local owner="$1" chart="$2" version="$3" token_response token status

  token_response="$(curl -fsSL -u "${GITHUB_ACTOR}:${GITHUB_TOKEN}" \
    "https://ghcr.io/token?scope=repository:${owner}/${chart}:pull&service=ghcr.io")" || {
    echo "registry auth request failed for ${owner}/${chart}; aborting (fail closed)" >&2
    exit 1
  }
  token="$(printf '%s' "${token_response}" | grep -oE '"token"[[:space:]]*:[[:space:]]*"[^"]+"' |
    sed -E 's/.*:"([^"]+)"$/\1/')"
  if [ -z "${token}" ]; then
    echo "registry auth response for ${owner}/${chart} had no token; aborting (fail closed)" >&2
    exit 1
  fi

  status="$(curl -s -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer ${token}" \
    -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
    "https://ghcr.io/v2/${owner}/${chart}/manifests/${version}")" || {
    echo "registry unreachable checking ${owner}/${chart}:${version}; aborting (fail closed)" >&2
    exit 1
  }

  case "${status}" in
    404) echo missing ;;
    200) echo published ;;
    *)
      echo "ambiguous registry response (HTTP ${status}) for ${owner}/${chart}:${version};" \
        "aborting (fail closed)" >&2
      exit 1
      ;;
  esac
}

charts="$(list_charts)"
if [ -z "${charts}" ]; then
  echo "no charts present; nothing to plan" >&2
  echo "[]"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "charts=[]" >>"${GITHUB_OUTPUT}"
  fi
  exit 0
fi

entries=()
while IFS= read -r chart; do
  [ -z "${chart}" ] && continue
  name="$(chart_field "${chart}" name)"
  version="$(chart_field "${chart}" version)"
  path="${chart#"${REPO_ROOT}"/}"

  echo "==> ${name} ${version}: checking ghcr.io/${OWNER}/${name}" >&2

  # Plain assignment, not a case/if subject directly: probe_registry's exit on abort must
  # reach `set -e` here, and a command substitution used as a compound command's subject
  # runs in a subshell where that exit would otherwise go unnoticed.
  result="$(probe_registry "${OWNER}" "${name}" "${version}")"

  case "${result}" in
    missing)
      echo "    not yet published; will release" >&2
      entries+=("{\"chart\":\"${name}\",\"path\":\"${path}\",\"version\":\"${version}\"}")
      ;;
    published)
      echo "    already published; skipping" >&2
      ;;
  esac
done <<<"${charts}"

json="[]"
if [ "${#entries[@]}" -gt 0 ]; then
  json="$(
    IFS=,
    echo "[${entries[*]}]"
  )"
fi

echo "${json}"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "charts=${json}" >>"${GITHUB_OUTPUT}"
fi
