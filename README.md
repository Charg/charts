# charts

Helm charts published as OCI artifacts to GitHub Packages, signed keylessly with cosign.

| Chart | Description |
| ----- | ----------- |
| [technitium-dns-server](charts/technitium-dns-server) | Self-hosted authoritative and recursive DNS server with a web console, DNSSEC, and ad/malware blocking. |

Standing up Technitium's native HA clustering across replicas is a manual, one-time step by
design: see [charts/technitium-dns-server/docs/clustering.md](charts/technitium-dns-server/docs/clustering.md).

## Local development

Requires nix with flakes enabled and a working Docker daemon. The flake provides the whole
toolchain (helm and helm-unittest, chart-testing, kubeconform, kind, kubectl, yamllint, yamale,
cosign, just). Enter the dev shell:

```bash
nix develop
```

The recipes below are the whole interface. CI runs these exact recipes.

```bash
just lint          # ct lint, yamllint, kubeconform over rendered manifests
just unit          # helm-unittest across all charts
just cluster-up    # create a kind cluster: 1 control-plane, 3 workers
just cluster-down  # delete it
```

To run a single recipe without entering the shell first: `nix develop -c just lint`.

## Layout

```
flake.nix        the toolchain; flake.lock pins every tool version
justfile         recipes; each is a one-line shim over hack/
charts/          one directory per chart
hack/            every real command
ct.yaml          chart-testing configuration
```

Bumping a tool is a `flake.lock` change (`nix flake update`). No version string is duplicated
in a recipe or a CI workflow.

## Continuous integration

Pull requests install nix and run the same recipes a developer runs locally: `just lint` and
`just unit` in one job, `just cluster-up`, `just e2e` and `just cluster-down` in another. If the
host's firewall or CNI interferes with kind's pod network during a local integration run, use
`just container-e2e` instead, which nests the cluster (and the same flake toolchain) inside a
container.

## Releases

Distribution is OCI only.

Merging a chart version bump to `main` publishes that chart to
`ghcr.io/charg/<chart>` (the repository owner, lowercased, since GHCR rejects uppercase
path segments). The release workflow decides what to publish by querying the registry for
each chart's current version, not by diffing git history, and aborts rather than publish on
any ambiguous registry response. Each published version is signed keylessly with cosign
against its digest, verified in the same run, and carries build provenance.

GHCR creates a new package as private with no API to change that, so the first time a chart
name is published, someone with admin access has to flip its visibility to public once in the
package's GitHub web UI. Every later version push to that same package inherits whatever
visibility it currently has, so this is a one-time flip per chart, not per version.

## Installing a chart

```bash
helm install my-release oci://ghcr.io/charg/<chart> --version <version>
```

Chart names match the table above; versions match each chart's `Chart.yaml`.

## Verifying a chart

Each published version is signed keylessly with cosign against its resolved digest, not its tag
(tags are mutable, a signature over one would assert nothing), and carries GitHub build
provenance attested via `actions/attest-build-provenance`. Both are verifiable by anyone, without
trusting this repository's maintainers, only GitHub's OIDC issuer.

Resolve the digest first (`helm pull` prints it, same as the release workflow does):

```bash
helm pull oci://ghcr.io/charg/<chart> --version <version>
```

Verify the cosign signature against the release workflow's own identity:

```bash
cosign verify \
  --certificate-identity "https://github.com/Charg/charts/.github/workflows/release.yaml@refs/heads/main" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
  ghcr.io/charg/<chart>@<digest>
```

Verify build provenance:

```bash
gh attestation verify oci://ghcr.io/charg/<chart>@<digest> --repo Charg/charts
```

Both commands need to reach `ghcr.io`; while a chart's package is still private (see the
one-time visibility flip above), that means authenticating first (`helm registry login
ghcr.io`, or however `cosign`/`gh` are configured to reach GHCR), the same login `helm pull`
would need.

## Conventions

Charts live under `charts/<name>/`. `ct` is configured with version-increment checking
against `main`, so any change to a chart must bump its `version` in `Chart.yaml` or lint
fails.
