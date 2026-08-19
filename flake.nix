{
  description = "nix-copy-closure over dumbpipe, served by a signing harmonia cache";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      forAllSystems = nixpkgs.lib.genAttrs [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        rec {
          nix-wormhole = pkgs.writeShellApplication {
            name = "nix-wormhole";
            runtimeInputs = with pkgs; [
              dumbpipe
              harmonia
              nix
              coreutils
            ];
            text = builtins.readFile ./nix-wormhole.sh;
          };
          default = nix-wormhole;
        }
      );
    };
}
