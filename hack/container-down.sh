#!/usr/bin/env bash
# Removes the nested integration container and everything inside it. Safe to run when absent.

source "$(dirname "${BASH_SOURCE[0]}")/tools.sh"

require_tools docker

CONTAINER="${E2E_CONTAINER_NAME:-charts-e2e-dind}"

if docker inspect "${CONTAINER}" >/dev/null 2>&1; then
  docker rm --force --volumes "${CONTAINER}" >/dev/null
  echo "removed ${CONTAINER}"
else
  echo "${CONTAINER} does not exist"
fi
