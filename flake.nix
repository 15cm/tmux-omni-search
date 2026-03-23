{
  description = "tmux-omni-search";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      eachSystem = nixpkgs.lib.genAttrs [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
    in {
      packages = eachSystem (system:
        let
          pkgs = import nixpkgs { inherit system; };
          package = pkgs.callPackage ./nix/pkgs/default.nix { };
        in {
          default = package;
          tmux-omni-search = package;
        });

      devShells = eachSystem (system:
        let
          pkgs = import nixpkgs { inherit system; };
        in {
          default = pkgs.mkShell {
            packages = [
              pkgs.bash
              pkgs.tmux
              pkgs.fzf
              pkgs.jujutsu
            ];
          };
        });
    };
}
