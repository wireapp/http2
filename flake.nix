{
  nixConfig.allow-import-from-derivation = true;
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    parts.url = "github:hercules-ci/flake-parts";
    haskell-flake.url = "github:srid/haskell-flake";
    pre-commit-hooks.url = "github:cachix/pre-commit-hooks.nix";
    http-semantics.url = "https://hackage.haskell.org/package/http-semantics-0.1.1/http-semantics-0.1.1.tar.gz";
    http-semantics.flake = false;
    network-run.url = "https://hackage.haskell.org/package/network-run-0.3.0/network-run-0.3.0.tar.gz";
    network-run.flake = false; 
  };
  outputs = inputs:
    inputs.parts.lib.mkFlake {inherit inputs;} {
      systems = ["x86_64-linux"];
      imports = [
        inputs.haskell-flake.flakeModule
        inputs.pre-commit-hooks.flakeModule
      ];

      perSystem = {
        config,
        pkgs,
        ...
      }: {
        pre-commit = {
          check.enable = true;
          settings.hooks = {
            cabal-fmt.enable = false;
            hlint.enable = false;
            fourmolu.enable = true;

            alejandra.enable = true;
            statix.enable = true;
            deadnix.enable = true;
          };
        };
        haskellProjects.default = {
          devShell.hoogle = false;
          packages = {
            http-semantics.source = inputs.http-semantics;
            time-manager.source = "0.1.0";
            network-control.source = "0.1.0";
            network-run.source = inputs.network-run;
            auto-update.source = "0.2.0";
          };
          settings = {};
          devShell.mkShellArgs.shellHook = config.pre-commit.installationScript;
        };
      };
    };
}
