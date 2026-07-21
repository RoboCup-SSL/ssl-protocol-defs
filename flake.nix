{
  description = "RoboCup SSL protocol definitions";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [ pkgs.protobuf pkgs.buf pkgs.gnumake ];
        };
      });

      checks = forAllSystems (pkgs: {
        proto-compile = pkgs.runCommand "proto-compile-check"
          { buildInputs = [ pkgs.protobuf pkgs.gnumake ]; }
          ''
            cd ${self}
            make check
            touch $out
          '';
      });
    };
}
