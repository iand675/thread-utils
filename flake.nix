{
  description = "Missing thread utilities for Haskell";
  outputs =
    { self, nixpkgs, ... }:
    let
      forAllSystems =
        withPkgs:
        nixpkgs.lib.genAttrs nixpkgs.lib.systems.flakeExposed (
          system:
          withPkgs {
            inherit system;
            pkgs = import nixpkgs { inherit system; };
          }
        );
    in {
      devShells = forAllSystems ({pkgs, ...}: {
        default = pkgs.mkShell {
          buildInputs = with pkgs; [
            cabal-install
            haskell.compiler.ghc910
          ];
        };
      });
    };

  inputs = {
    nixpkgs.url = "flake:nixpkgs";
  };
}

