# charts: dev tasks. Every recipe assumes the nix toolchain is on PATH: run inside the
# dev shell (`nix develop`, or direnv via .envrc), or one-shot as `nix develop -c just <recipe>`.
# Recipes are one-line shims over scripts in hack/; CI calls the same recipes.

set shell := ["bash", "-euo", "pipefail", "-c"]

# List available recipes.
_default:
    @just --list --unsorted

# Run every linter: what CI and the pre-commit hook run.
lint:
    hack/lint.sh

# Format nix files.
fmt:
    git ls-files -z -- '*.nix' | xargs -0 --no-run-if-empty nixfmt

# Install the prek git hooks from .pre-commit-config.yaml (once per clone).
install-hooks:
    prek install

# List the dev shell's packages and the versions flake.lock pins them to.
versions:
    @nix eval --raw ".#devShells.$(nix eval --impure --raw --expr builtins.currentSystem).default.nativeBuildInputs" \
      --apply 'ps: builtins.concatStringsSep "" (map (p: "${p.pname or p.name} ${p.version or "-"}\n") ps)'

# Run helm-unittest across all charts.
unit:
    hack/unit.sh

# Create the kind test cluster (1 control-plane, 3 workers).
cluster-up:
    hack/cluster-up.sh

# Delete the kind test cluster.
cluster-down:
    hack/cluster-down.sh

# Install ci/ scenarios (all charts, the named ones, or --changed) and assert HA topology.
e2e *args:
    hack/e2e.sh {{ args }}

# Run cluster-up, e2e and cluster-down nested inside a container.
container-e2e:
    hack/container-e2e.sh

# Remove the nested integration container.
container-down:
    hack/container-down.sh

# Show which charts need publishing (queries the registry, fails closed).
release-plan:
    hack/release-plan.sh

# Package, push, sign and verify one chart (CHART is charts/<name>).
release-publish chart:
    hack/release-publish.sh {{ chart }}

verify-images *charts:
    hack/verify-images.sh {{ charts }}

scan-images *charts:
    hack/scan-images.sh {{ charts }}
