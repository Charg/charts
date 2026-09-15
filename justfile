# Helm charts: dev tasks. Every recipe assumes the nix toolchain is on PATH; run inside the
# dev shell (`nix develop`) or invoke a recipe directly as `nix develop -c just <recipe>`.

set shell := ["bash", "-cu"]

# List available recipes.
_default:
    @just --list --unsorted

# Lint charts: ct lint, yamllint, kubeconform over rendered manifests.
lint:
    hack/lint.sh

# Run helm-unittest across all charts.
unit:
    hack/unit.sh

# Create the kind test cluster (1 control-plane, 3 workers).
cluster-up:
    hack/cluster-up.sh

# Delete the kind test cluster.
cluster-down:
    hack/cluster-down.sh

# Install every ci/ scenario into the cluster and assert HA topology.
e2e:
    hack/e2e.sh

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
