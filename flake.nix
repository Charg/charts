{
  description = "Helm charts published to ghcr.io/charg/charts";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShellNoCC {
          packages = [
            # Task runner and git hooks.
            pkgs.just
            pkgs.prek
            # Lint (hack/lint.sh).
            pkgs.actionlint
            pkgs.nixfmt
            pkgs.shellcheck
            pkgs.yamllint
            pkgs.zizmor
            # helm-charts flavour (hack/lint.d/helm-charts.sh). helm-unittest is a helm plugin;
            # wrapHelm puts it on HELM_PLUGINS so `helm unittest` works without an install step.
            (pkgs.wrapHelm pkgs.kubernetes-helm {
              plugins = [ pkgs.kubernetes-helmPlugins.helm-unittest ];
            })
            pkgs.chart-testing
            pkgs.yamale
            pkgs.kubeconform
            # Used by the scripts directly.
            pkgs.git
            # e2e: kind clusters, and the nested-container path.
            pkgs.kind
            pkgs.kubectl
            pkgs.docker-client
            # Release signing, and misconfiguration and CVE scanning of rendered manifests and the
            # images they deploy.
            pkgs.cosign
            pkgs.trivy
            # Structured queries over rendered manifests (image lists, Chart.yaml annotations),
            # registry probing and JSON assembly.
            pkgs.yq-go
            pkgs.curl
            pkgs.jq
          ];
        };
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt);
    };
}
