{
  description = "Helm charts: development toolchain and CI environment";

  # Stable channel: pins helm on the 3.x line consumers render with, not the 4.x that
  # nixpkgs-unstable has moved to and that chart-testing's bundled libraries predate.
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
      devShells = forAllSystems (
        pkgs:
        let
          # helm-unittest is a helm plugin, not a standalone binary; wrapHelm bakes it into
          # HELM_PLUGINS so `helm unittest` resolves without a separate install step.
          helm = pkgs.wrapHelm pkgs.kubernetes-helm {
            plugins = [ pkgs.kubernetes-helmPlugins.helm-unittest ];
          };
        in
        {
          default = pkgs.mkShellNoCC {
            packages = [
              helm
              pkgs.chart-testing # ct
              pkgs.kubeconform
              pkgs.kind
              pkgs.kubectl
              pkgs.yamllint
              pkgs.yamale
              pkgs.cosign
              pkgs.just
              # Used by the scripts directly: registry probing, JSON assembly, the
              # nested-container e2e path, and source-tree copies.
              pkgs.git
              pkgs.curl
              pkgs.jq
              pkgs.docker-client
            ];
          };
        }
      );
    };
}
