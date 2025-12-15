{
  description = "xattr_stream development environment (native + Cosmopolitan APE)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        cosmoccVersion = "4.0.2";
        cosmoccHash = "sha256-6KZv7KU2rJhwfc9k6z9I6ZdfIS1KqRFLZUo8YyuD7ZY=";
        cosmoccSrc = pkgs.fetchzip {
          url = "https://cosmo.zip/pub/cosmocc/cosmocc-${cosmoccVersion}.zip";
          hash = cosmoccHash;
          stripRoot = false;
        };
        cosmoccBin = pkgs.stdenvNoCC.mkDerivation {
          pname = "cosmocc-bin";
          version = cosmoccVersion;
          src = cosmoccSrc;
          phases = [ "installPhase" ];
          installPhase = ''
            mkdir -p $out
            cp -r $src/* $out/
          '';
        };

        native = pkgs.stdenv.mkDerivation {
          pname = "xattr_stream";
          version = "0.0.0";
          src = ./.;
          nativeBuildInputs = [ pkgs.gcc pkgs.gnumake ];
          buildPhase = ''
            make native
          '';
          installPhase = ''
            mkdir -p $out/bin
            cp bin/xattr_stream $out/bin/xattr_stream
          '';
        };

        ape = pkgs.stdenv.mkDerivation {
          pname = "xattr_stream_ape";
          version = "0.0.0";
          src = ./.;
          nativeBuildInputs = [ pkgs.unzip cosmoccBin pkgs.gnumake ];
          buildPhase = ''
            make ape
          '';
          installPhase = ''
            mkdir -p $out/bin
            cp bin/xattr_stream_ape.com $out/bin/xattr_stream_ape.com
          '';
        };
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            bashInteractive
            gcc
            clang
            gnumake
            coreutils
            gnugrep
            diffutils
          ];
          shellHook = ''
            echo "xattr_stream dev shell"
            echo "  make native"
            echo "  make ape   # Linux x86_64 host only"
            echo "  ./test"
            export PATH="${cosmoccBin}/bin:$PATH"
          '';
        };

        packages = {
          default = native;
          native = native;
          ape = ape;
        };
      });
}
