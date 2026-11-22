# AGENTS.md

<!-- BEGIN TEMPLATE: managed by Charg/template through `copier update`. Edit it there, not here. -->

## Toolchain

- **The toolchain is the nix flake.** Run everything inside `nix develop` (direnv loads it through
  `.envrc`), or one-shot as `nix develop -c just <recipe>`. Never install tools ad hoc or pin a tool
  version in a script or workflow: add it to `flake.nix`, bump it with `nix flake update`.
- **`just` is the only interface.** Recipes are one-line shims over scripts in `hack/`, and CI calls
  the same recipes a developer runs locally. New behaviour goes in `hack/`, then gets a recipe, then
  CI calls the recipe. No logic in workflow YAML beyond setup and secrets.
- **`hack/` scripts** are bash and start with `source "$(dirname "${BASH_SOURCE[0]}")/tools.sh"`,
  which sets `set -euo pipefail` and holds the shared helpers (`log`, `die`, `require_tools`,
  `repo_files`).
- Run `just lint` before committing. The prek hook (`just install-hooks`) runs it on commit.
- Plans, tickets and throwaway output go in `.scratch/` (gitignored).

## GitHub Actions

- Workflows start with `permissions: {}` and grant each job only what it needs. Check out with
  `persist-credentials: false`.
- Pin every `uses:` to a full commit SHA with a version comment.
- After adding or bumping an action, regenerate `.github/workflows/actions.lock` with
  `gh actions-lock --no-narrow`. Without `--no-narrow` it rewrites SHA pins to tags, which zizmor's
  `unpinned-uses` audit rejects.
- Renovate policy (release age, automerge, nix lock maintenance) comes from the shared preset in
  `Charg/template` (`renovate/default.json5`). `.github/renovate.json5` holds only this repo's
  additions.

## Commits

- Conventional commits: `feat:`, `fix:`, `chore:`, `ci:`, `docs:`, `refactor:`, `test:`,
  optionally scoped (`feat(api): ...`).
- Work on a branch and open a PR. PRs squash-merge. Don't commit to `main` directly.
- Commit only when asked.

## Helm charts

- Charts live at `charts/<name>/`. helm 3 (with helm-unittest), chart-testing and kubeconform come
  from the flake, which stays on nixos-26.05: nixos-unstable ships helm 4.
- `just lint` runs `ct lint --all` (`ct.yaml`) and kubeconform over the manifests each chart renders
  with `values.yaml` and each `ci/*-values.yaml` (`hack/lint.d/helm-charts.sh`). yamllint skips
  `charts/*/templates/`, which is Go templates rather than YAML.
- Renovate leaves digest-only bumps of images (a tag re-pushed upstream) for a human.

## Template

- Shared files (flake, justfile, `hack/tools.sh`, `hack/lint.sh`, `hack/lint.d/`, lint configs, CI,
  this section) come from `Charg/template`; the answers are in `.copier-answers.yml`, which is
  never edited by hand. Pull template changes with `copier update` and resolve any conflicts it
  leaves. Add a flavour with `copier update --data 'flavours=[...]'`, listing every flavour wanted.
- Projects extend the shared files freely (packages in `flake.nix`, recipes, lint steps; a new lint
  step can be its own script in `hack/lint.d/`);
  `copier update` merges template changes around those edits.
- Only the text between the TEMPLATE markers in this file belongs to the template. Project rules go
  under `## Project

Helm charts published as OCI artifacts to `ghcr.io/charg/charts/<name>`, signed keylessly with
cosign. Images built by the sibling `Charg/containers` repo are pinned here by digest. `README.md`
has the chart list, the recipes and how CI and releases work.

- Every chart declares the Pod Security Standard its defaults meet in the
  `charg.github.io/pod-security` annotation (`restricted`, `baseline` or `privileged`); `just e2e`
  installs it under that level.
- Every image a chart renders is pinned by digest. A chart's `appVersion` is its image tag, and the
  `charg.github.io/image-digest` annotation next to it pins that tag's digest; Renovate rewrites
  both together (`.github/renovate.json5`).
- Changing a chart means bumping its `version`: `just lint` checks every chart changed against
  `main` (`hack/lint.d/charts.sh`), and the release publishes a chart whose version isn't in the
  registry yet.
- Each `charts/<name>/ci/*-values.yaml` is a scenario that lint renders and `just e2e` installs. A
  chart may require values and deliberately fail to render from `values.yaml` alone.
- A HIGH trivy finding a chart can't avoid is accepted, with the reason, in its own
  `.trivyignore.yaml`.
