#!/usr/bin/env bash
# Full local integration run, nested inside a container so the host's firewall and CNI cannot
# interfere with the cluster's pod network.

source "$(dirname "${BASH_SOURCE[0]}")/tools.sh"

"${REPO_ROOT}/hack/in-container.sh" cluster-up e2e cluster-down
