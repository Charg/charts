#!/usr/bin/env bash
# Logs helm and cosign in to ghcr.io. Credentials come from the environment, never from
# arguments: an argument would be visible in the process list, and a workflow that
# interpolated the secret into its own shell text would leak it into the run's command trace.
#
# helm and cosign read registry credentials from different files. helm writes to and reads
# HELM_REGISTRY_CONFIG (~/.config/helm/registry/config.json); cosign uses the go-containerregistry
# keychain, which reads the Docker config (~/.docker/config.json). Logging in only helm leaves
# cosign unauthenticated, so pushing the signature layer fails even though the chart push
# succeeded. Log both in against the same credentials.

source "$(dirname "${BASH_SOURCE[0]}")/tools.sh"

require_tools helm cosign

: "${GITHUB_ACTOR:?GITHUB_ACTOR must be set}"
: "${GITHUB_TOKEN:?GITHUB_TOKEN must be set}"

printf '%s' "${GITHUB_TOKEN}" |
  helm registry login ghcr.io --username "${GITHUB_ACTOR}" --password-stdin

printf '%s' "${GITHUB_TOKEN}" |
  cosign login ghcr.io --username "${GITHUB_ACTOR}" --password-stdin
