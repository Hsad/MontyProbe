{
  description = "Monty - Evolving Sensors: Learn Numenta's Thousand Brains via spaceship sim";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            odin
            raylib
            # raylib runtime deps
            libGL
            libx11
            libxrandr
            libxinerama
            libxcursor
            libxi
            wayland
            wayland-protocols
            libxkbcommon
          ];

          nativeBuildInputs = with pkgs; [
            pkg-config
          ];

          shellHook = ''
            echo "Monty dev shell ready"
            echo "  odin: $(odin version 2>/dev/null || echo 'checking...')"
            echo "  build: odin run src/ -out:monty"
          '';

          LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath (with pkgs; [
            raylib
            libGL
            libx11
            libxrandr
            libxinerama
            libxcursor
            libxi
            wayland
            libxkbcommon
          ]);
        };

        packages.default = pkgs.stdenv.mkDerivation {
          pname = "monty";
          version = "0.1.0";
          src = ./.;

          nativeBuildInputs = with pkgs; [ odin pkg-config ];
          buildInputs = with pkgs; [
            raylib
            libGL
            libx11
            libxrandr
            libxinerama
            libxcursor
            libxi
          ];

          buildPhase = ''
            odin build src/ -out:monty -o:speed
          '';

          installPhase = ''
            mkdir -p $out/bin
            cp monty $out/bin/
          '';
        };
      });
}
