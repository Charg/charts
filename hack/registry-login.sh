#!/usr/bin/env bash
# Logs helm in to ghcr.io. Credentials come from the environment, never from arguments: an
# argument would be visible in the process list, and a workflow that interpolated the secret
# into its own shell text would leak it into the run's command trace.

source "$(dirname "${BASH_SOURCE[0]}")/tools.sh"

require_tools helm

: "${GITHUB_ACTOR:?GITHUB_ACTOR must be set}"
: "${GITHUB_TOKEN:?GITHUB_TOKEN must be set}"

printf '%s' "${GITHUB_TOKEN}" |
  helm registry login ghcr.io --username "${GITHUB_ACTOR}" --password-stdin
