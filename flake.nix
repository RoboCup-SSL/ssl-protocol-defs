{
  description = "RoboCup SSL protocol definitions";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    uv2nix = {
      url = "github:pyproject-nix/uv2nix";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.uv2nix.follows = "uv2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { self, nixpkgs, pyproject-nix, uv2nix, pyproject-build-systems }:
    let
      inherit (nixpkgs) lib;
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = lib.genAttrs systems;

      # Python deps (scapy, protobuf) for the Wireshark dissector's test-time pcap
      # generation -- see wireshark/pyproject.toml. Kept as its own uv workspace
      # since it's the only Python in this repo and isn't an installable package.
      workspace = uv2nix.lib.workspace.loadWorkspace { workspaceRoot = ./wireshark; };
      overlay = workspace.mkPyprojectOverlay { sourcePreference = "wheel"; };

      pythonSets = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        (pkgs.callPackage pyproject-nix.build.packages { python = pkgs.python3; }).overrideScope
          (lib.composeManyExtensions [
            pyproject-build-systems.overlays.wheel
            overlay
          ])
      );
    in
    {
      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          pythonSet = pythonSets.${system};
          venv = pythonSet.mkVirtualEnv "ssl-dissector-test-env" workspace.deps.default;
        in
        {
          default = pkgs.mkShell {
            packages = [ pkgs.protobuf pkgs.buf pkgs.gnumake pkgs.wireshark-cli venv pkgs.uv ];
            env = {
              UV_NO_SYNC = "1";
              UV_PYTHON = pythonSet.python.interpreter;
              UV_PYTHON_DOWNLOADS = "never";
            };
            shellHook = ''
              unset PYTHONPATH
            '';
          };
        }
      );

      checks = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          venv = pythonSets.${system}.mkVirtualEnv "ssl-dissector-test-env" workspace.deps.default;
        in
        {
          proto-compile = pkgs.runCommand "proto-compile-check"
            { buildInputs = [ pkgs.protobuf pkgs.gnumake ]; }
            ''
              cd ${self}
              make compile-protos
              touch $out
            '';

          wireshark-dissector-test = pkgs.runCommand "wireshark-dissector-test"
            {
              buildInputs = [ pkgs.protobuf pkgs.wireshark-cli venv ];
              PROTOBUF_INCLUDE_DIR = "${pkgs.protobuf}/include";
            }
            ''
              cd ${self}
              python3 wireshark/tests/run_tests.py
              touch $out
            '';
        }
      );
    };
}
