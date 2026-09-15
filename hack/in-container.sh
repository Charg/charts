#!/usr/bin/env bash
# Runs just recipes inside a privileged Docker-in-Docker container, using the same nix toolchain
# the host and CI use.
#
# Why this exists: kind puts its nodes on a Docker bridge, and bridged node-to-node traffic is
# passed through the HOST's netfilter hooks. A host with a strict reverse-path filter, a
# restrictive FORWARD policy, or its own CNI already installed will silently drop cross-node pod
# traffic, which looks exactly like a broken chart. Nesting the cluster inside a container puts
# that bridge in the container's own network namespace, where the host's rules do not apply.
#
# CI on a clean runner does not need this: it enters the flake dev shell and runs the same just
# recipes directly. There is one flake and one set of recipes either way, so the paths cannot
# drift.

source "$(dirname "${BASH_SOURCE[0]}")/tools.sh"

require_tools docker

CONTAINER="${E2E_CONTAINER_NAME:-charts-e2e-dind}"
DIND_IMAGE="docker:28-dind"

if [ "$#" -eq 0 ]; then
  echo "usage: $(basename "$0") <just-recipe>..." >&2
  exit 1
fi

if ! docker inspect "${CONTAINER}" >/dev/null 2>&1; then
  echo "==> starting ${CONTAINER}"
  # DOCKER_TLS_CERTDIR empty keeps the inner daemon on its local socket: nothing is exposed
  # outside this container, so no port is published on the host.
  docker run --detach --privileged \
    --name "${CONTAINER}" \
    --env DOCKER_TLS_CERTDIR= \
    "${DIND_IMAGE}" --host=unix:///var/run/docker.sock >/dev/null
fi

docker start "${CONTAINER}" >/dev/null 2>&1 || true

echo "==> waiting for the inner Docker daemon"
for _ in $(seq 1 60); do
  docker exec "${CONTAINER}" docker info >/dev/null 2>&1 && break
  sleep 2
done
docker exec "${CONTAINER}" docker info >/dev/null 2>&1 || {
  echo "inner Docker daemon did not come up in ${CONTAINER}" >&2
  exit 1
}

# Install a single-user nix once per container lifetime. The dind image is Alpine (musl), so
# gcompat provides the glibc shim the official nix binaries need; xz/tar/curl are the installer's
# own dependencies. Sandboxing is disabled because the nested daemon has no user-namespace setup
# to build in. Flakes are enabled globally so `nix develop` resolves flake.lock.
docker exec "${CONTAINER}" sh -c '
  set -e
  if [ ! -e /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ] &&
     [ ! -e "$HOME/.nix-profile/etc/profile.d/nix.sh" ]; then
    apk add --no-cache bash curl xz git tar gcompat >/dev/null
    mkdir -p /etc/nix
    printf "experimental-features = nix-command flakes\nsandbox = false\n" >/etc/nix/nix.conf
    curl -fsSL https://nixos.org/nix/install | sh -s -- --no-daemon >/dev/null
  fi
'

# Copy rather than bind-mount: the host source is fine to share, but the container installs its
# own /nix store and must own the tree it builds from. Only tracked and untracked-but-not-ignored
# files are sent, which includes flake.nix and flake.lock.
echo "==> syncing the repo into ${CONTAINER}"
docker exec "${CONTAINER}" rm -rf /work
docker exec "${CONTAINER}" mkdir -p /work
git -C "${REPO_ROOT}" ls-files -z --cached --others --exclude-standard |
  tar -cf - -C "${REPO_ROOT}" --null --files-from=- |
  docker exec --interactive "${CONTAINER}" tar -xf - -C /work

echo "==> just $*"
# Source the single-user nix profile, then enter the flake dev shell to run the recipes. bash is
# required: the installer profile script uses bashisms and the hack/ scripts have a bash shebang.
docker exec --workdir /work "${CONTAINER}" bash -lc '
  . "$HOME/.nix-profile/etc/profile.d/nix.sh"
  exec nix develop -c just "$@"
' bash "$@"
