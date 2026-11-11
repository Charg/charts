# charts

Helm charts published as OCI artifacts to GitHub Packages, signed keylessly with cosign.

| Chart | Description |
| ----- | ----------- |
| [anki-sync-server](charts/anki-sync-server) | Anki's self-hosted sync server, for syncing decks, review history and media between Anki clients. |
| [anythingllm](charts/anythingllm) | All-in-one AI workspace with chat, RAG over your documents and agents, against any LLM provider. |
| [hermes-agent](charts/hermes-agent) | Nous Research's self-improving AI agent with an OpenAI-compatible API server and web dashboard. |
| [technitium-dns-server](charts/technitium-dns-server) | Self-hosted authoritative and recursive DNS server with a web console, DNSSEC, and ad/malware blocking. |
| [vaultwarden](charts/vaultwarden) | Unofficial Bitwarden-compatible password manager server with the web vault, admin panel, SSO and SMTP. |

Standing up Technitium's native HA clustering across replicas is a manual, one-time step by
design: see [charts/technitium-dns-server/docs/clustering.md](charts/technitium-dns-server/docs/clustering.md).

## Local development

Requires nix with flakes enabled and a working Docker daemon. The flake provides the whole
toolchain (helm and helm-unittest, chart-testing, kubeconform, kind, kubectl, yamllint, yamale,
cosign, trivy, zizmor, actionlint, yq, just). Enter the dev shell:

```bash
nix develop
```

The recipes below are the whole interface. CI runs these exact recipes.

```bash
just lint          # ct lint, yamllint, actionlint + zizmor, kubeconform and trivy over rendered manifests
just unit          # helm-unittest across all charts
just verify-images # every deployed image pinned by digest; Charg/containers images signed
just scan-images   # trivy CVE scan of every deployed image (--changed: only changed charts)
just cluster-up    # create a kind cluster: 1 control-plane, 3 workers
just e2e           # install every ci/ scenario under its chart's Pod Security level
                   #   (--changed: only changed charts; --list: print the selection and stop)
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
`just unit` in one job, `just verify-images` and `just scan-images --changed` in a second,
`just cluster-up`, `just e2e --changed` and `just cluster-down` in a third. Every job starts with no
token permissions beyond reading the repository, and runs under
[harden-runner](https://github.com/step-security/harden-runner) in audit mode, recording its
outbound connections. If the
host's firewall or CNI interferes with kind's pod network during a local integration run, use
`just container-e2e` instead, which nests the cluster (and the same flake toolchain) inside a
container.

The integration job installs only the charts a pull request changes, as `ct list-changed`
reports them against `main`. A change to anything outside `charts/` (`hack/`, the flake,
`ct.yaml`, the workflows, the kind config) selects every chart instead, because shared tooling
can break a chart whose own files are untouched; only `README.md`, `LICENSE` and
`.github/renovate.json5` are exempt. When nothing is selected the job skips creating the cluster
and still passes, so it stays usable as a required check. The HA topology assertions run only
when `technitium-dns-server` is selected. Locally, `just e2e --changed --list` shows what CI
would install.

## Releases

Distribution is OCI only.

Merging a chart version bump to `main` publishes that chart to
`ghcr.io/charg/charts/<chart>` (the repository owner, lowercased, since GHCR rejects uppercase
path segments). The `charts/` path keeps chart names apart from images of the same name, which
[Charg/containers](https://github.com/Charg/containers) publishes under `ghcr.io/charg/containers/`.
Charts published before this layout, at `ghcr.io/charg/<chart>`, are no longer updated.

The release workflow decides what to publish by querying the registry for
each chart's current version, not by diffing git history, and aborts rather than publish on
any ambiguous registry response. Each chart is then published by the reusable
`publish-chart.yaml` workflow, which:

1. refuses a chart that renders an image not pinned by digest, or one of Charg/containers'
   images without a valid signature from that repository's release workflow;
2. pushes the chart, signs its digest keylessly with cosign and verifies the signature;
3. attests the list of images the chart deploys (see [Verifying a chart](#verifying-a-chart));
4. attests SLSA build provenance;
5. creates the GitHub release, from a separate job that can write to the repository but holds
   no OIDC token, so it cannot sign.

The signing job runs in the `release` environment, which must be restricted to the `main`
branch in the repository settings.

GHCR creates a new package as private with no API to change that, so the first time a chart
name is published, someone with admin access has to flip its visibility to public once in the
package's GitHub web UI. Every later version push to that same package inherits whatever
visibility it currently has, so this is a one-time flip per chart, not per version.

## Installing a chart

```bash
helm install my-release oci://ghcr.io/charg/charts/<chart> --version <version>
```

Chart names match the table above; versions match each chart's `Chart.yaml`.

## Verifying a chart

Each published version is signed keylessly with cosign against its resolved digest, not its tag
(tags are mutable, a signature over one would assert nothing), and carries GitHub build
provenance attested via `actions/attest-build-provenance`. Both are verifiable by anyone, without
trusting this repository's maintainers, only GitHub's OIDC issuer.

Resolve the digest first (`helm pull` prints it, same as the release workflow does):

```bash
helm pull oci://ghcr.io/charg/charts/<chart> --version <version>
```

Verify the cosign signature against the publish workflow's own identity:

```bash
cosign verify \
  --certificate-identity "https://github.com/Charg/charts/.github/workflows/publish-chart.yaml@refs/heads/main" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
  ghcr.io/charg/charts/<chart>@<digest>
```

Versions published before signing moved into `publish-chart.yaml` carry the identity
`https://github.com/Charg/charts/.github/workflows/release.yaml@refs/heads/main` instead.

Verify build provenance, pinned to the workflow that built it:

```bash
gh attestation verify oci://ghcr.io/charg/charts/<chart>@<digest> \
  --repo Charg/charts \
  --signer-workflow Charg/charts/.github/workflows/publish-chart.yaml
```

List the images a chart version deploys (every one pinned by digest), from its signed
attestation:

```bash
cosign verify-attestation \
  --type https://charg.github.io/attestations/chart-images/v1 \
  --certificate-identity "https://github.com/Charg/charts/.github/workflows/publish-chart.yaml@refs/heads/main" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
  ghcr.io/charg/charts/<chart>@<digest> | jq -r '.payload | @base64d | fromjson | .predicate.images[]'
```

Pin the digest, not only the version, wherever you install from: GHCR tags can be overwritten,
and a digest cannot.

### Enforcing verification

Flux can refuse an unverified chart before it is ever rendered:

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: vaultwarden
spec:
  url: oci://ghcr.io/charg/charts/vaultwarden
  ref:
    digest: sha256:<digest>
  layerSelector:
    mediaType: application/vnd.cncf.helm.chart.content.v1.tar+gzip
    operation: copy
  verify:
    provider: cosign
    matchOIDCIdentity:
      - issuer: ^https://token\.actions\.githubusercontent\.com$
        subject: ^https://github\.com/Charg/charts/\.github/workflows/publish-chart\.yaml@refs/heads/main$
```

Images built by Charg/containers can be enforced at admission, e.g. with Kyverno:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-charg-containers
spec:
  validationFailureAction: Enforce
  webhookTimeoutSeconds: 30
  rules:
    - name: charg-containers-signed
      match:
        any:
          - resources:
              kinds: [Pod]
      verifyImages:
        - imageReferences: ["ghcr.io/charg/containers/*"]
          mutateDigest: true
          verifyDigest: true
          attestors:
            - entries:
                - keyless:
                    issuer: https://token.actions.githubusercontent.com
                    subject: https://github.com/Charg/containers/.github/workflows/release.yaml@refs/heads/main
                    rekor:
                      url: https://rekor.sigstore.dev
```

Both commands need to reach `ghcr.io`; while a chart's package is still private (see the
one-time visibility flip above), that means authenticating first (`helm registry login
ghcr.io`, or however `cosign`/`gh` are configured to reach GHCR), the same login `helm pull`
would need.

## Conventions

Charts live under `charts/<name>/`. `ct` is configured with version-increment checking
against `main`, so any change to a chart must bump its `version` in `Chart.yaml` or lint
fails.

Every chart also carries, and lint or e2e enforce:

- **`charg.github.io/pod-security`** in `Chart.yaml` annotations: the
  [Pod Security Standard](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
  its defaults meet (`restricted` unless the image makes that impossible). e2e installs every
  `ci/` scenario into a namespace enforcing that level, so every scenario has to meet it too.
- **`charg.github.io/image-digest`** in `Chart.yaml` annotations: the digest of the
  `appVersion` image, used whenever `image.tag` and `image.digest` are left empty. Renovate
  updates it together with `appVersion`. Test hook images pin theirs in `values.yaml`
  (`tag: "<tag>@sha256:..."`). Lint and release refuse any rendered image without a digest.
- **`values.schema.json`**: closed at the top level and for `image`, the security contexts and
  `networkPolicy`, so a misspelt key fails the render instead of being silently dropped. A new
  value needs a schema entry, or `helm lint` fails.
- **`.trivyignore.yaml`** (optional, excluded by `.helmignore`): HIGH/CRITICAL trivy findings
  the chart cannot avoid, each with the reason and, for CVEs, an expiry.
