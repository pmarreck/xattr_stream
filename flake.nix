{
  description = "xattr_stream: cross-platform binary-safe file attributes (Zig core, C ABI, C CLI)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    zig-overlay = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, zig-overlay }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        zig = zig-overlay.packages.${system}."0.16.0";
        version = "0.2.0";
        src = pkgs.lib.cleanSource ./.;

        # Zig needs writable cache dirs inside the sandbox; no network is
        # required because build.zig.zon declares no dependencies.
        zigEnv = ''
          export HOME=$TMPDIR
          export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-global
          export ZIG_LOCAL_CACHE_DIR=$TMPDIR/zig-local
          ${pkgs.lib.optionalString pkgs.stdenv.isDarwin "unset NIX_CFLAGS_COMPILE NIX_LDFLAGS"}
        '';

        mkCheck = name: extraInputs: script: pkgs.stdenv.mkDerivation {
          name = "xattr_stream-${name}";
          inherit src;
          nativeBuildInputs = [ zig ] ++ extraInputs;
          dontConfigure = true;
          dontFixup = true;
          buildPhase = zigEnv + script;
          installPhase = ''
            mkdir -p $out
            echo passed > $out/${name}
          '';
        };

        native = pkgs.stdenv.mkDerivation {
          pname = "xattr_stream";
          inherit version src;
          nativeBuildInputs = [ zig ];
          dontConfigure = true;
          buildPhase = zigEnv + ''
            zig build -Doptimize=ReleaseFast --prefix $out
          '';
          dontInstall = true;
          meta = with pkgs.lib; {
            description = "Cross-platform binary-safe file attributes: library (C ABI) and CLI";
            license = licenses.mit;
            platforms = platforms.linux ++ platforms.darwin;
            mainProgram = "xattr-stream";
          };
        };

        # Every supported target, cross-compiled from this host.
        cross = pkgs.stdenv.mkDerivation {
          pname = "xattr_stream-cross";
          inherit version src;
          nativeBuildInputs = [ zig ];
          dontConfigure = true;
          buildPhase = zigEnv + ''
            zig build cross -Doptimize=ReleaseFast --prefix $out
          '';
          dontInstall = true;
        };
      in
      {
        packages = {
          default = native;
          inherit native cross;
        };

        checks = {
          # Zig unit + integration tests (real OS attribute calls on tmp fixtures).
          test-zig = mkCheck "test-zig" [ ] ''
            zig build test
          '';

          # The C CLI over the public header, driven by the Bash suite.
          test-cli = mkCheck "test-cli" [ pkgs.bashInteractive pkgs.coreutils pkgs.diffutils ] ''
            zig build
            bash tests/cli/test_cli.sh zig-out/bin/xattr-stream
          '';

          # Cross-compilation must succeed for all five targets even though only
          # the host can run them.
          test-cross = mkCheck "test-cross" [ ] ''
            zig build cross
            for t in x86_64-linux-musl aarch64-linux-musl aarch64-macos; do
              test -f zig-out/cross/$t/bin/xattr-stream || { echo "missing CLI for $t" >&2; exit 1; }
              test -f zig-out/cross/$t/lib/libxattr_stream.a || { echo "missing static lib for $t" >&2; exit 1; }
            done
            for t in x86_64-windows-gnu aarch64-windows-gnu; do
              test -f zig-out/cross/$t/bin/xattr-stream.exe || { echo "missing CLI for $t" >&2; exit 1; }
              test -f zig-out/cross/$t/lib/xattr_stream.lib || { echo "missing static lib for $t" >&2; exit 1; }
              test -f zig-out/cross/$t/lib/xattr_stream.dll || { echo "missing DLL for $t" >&2; exit 1; }
            done
          '';

          # Independent compilers/runtimes consuming the C ABI.
          test-consumer-c = mkCheck "test-consumer-c" [ pkgs.clang ] ''
            zig build
            clang -std=c99 -Wall -Wextra -Werror -pedantic -Izig-out/include \
              -o consumer_c tests/consumers/c/consumer.c zig-out/lib/libxattr_stream.a
            ./consumer_c
          '';
          test-consumer-rust = mkCheck "test-consumer-rust" [ pkgs.rustc ] ''
            zig build
            rustc --edition 2021 -O -L zig-out/lib -o consumer_rs tests/consumers/rust/consumer.rs
            ./consumer_rs
          '';
          test-consumer-luajit = mkCheck "test-consumer-luajit" [ pkgs.luajit ] ''
            zig build
            luajit tests/consumers/luajit/consumer.lua zig-out/lib/libxattr_stream${pkgs.stdenv.hostPlatform.extensions.sharedLibrary}
          '';
          test-consumer-zig = mkCheck "test-consumer-zig" [ ] ''
            cd tests/consumers/zig && zig build test
          '';
        };

        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            zig
            clang
            luajit
            rustc
            bashInteractive
            coreutils
            gnugrep
            diffutils
          ];
          shellHook = ''
            echo "xattr_stream dev shell (zig $(zig version))"
            echo "  ./build       native library + CLI into zig-out/"
            echo "  ./build_all   all five targets into zig-out/cross/"
            echo "  ./test        everything"
          '';
        };
      });
}
