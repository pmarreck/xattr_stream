{
  description = "xattr_stream: cross-platform binary-safe file attributes (Zig core, C ABI, C CLI)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    zig-overlay = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # A Rust toolchain with the standard libraries of all six platforms, for
    # cross-compiling the Rust implementation (nixpkgs' Rust has the host's only).
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, zig-overlay, rust-overlay }:
    {
      # For other flakes: add `xattr_stream.overlays.default` to nixpkgs
      # overlays, then use `pkgs.xattr_stream` (bin/, lib/, include/, and
      # lib/pkgconfig/xattr_stream.pc), e.g. in buildInputs with pkg-config.
      overlays.default = final: prev: {
        xattr_stream = self.packages.${prev.stdenv.hostPlatform.system}.default;
        # The Rust implementation: same C ABI and header, CLI xattr-stream-rs.
        xattr_stream_rs = self.packages.${prev.stdenv.hostPlatform.system}.rust;
      };
    } //
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        zig = zig-overlay.packages.${system}."0.16.0";
        version = "0.2.0";
        src = pkgs.lib.cleanSource ./.;

        # Zig dependencies (printable_binary) are fetched once into a
        # fixed-output derivation, then copied into the sandboxed builds'
        # global cache so `zig build` needs no network. Update the hash when
        # build.zig.zon changes: set it to pkgs.lib.fakeHash, build, copy the
        # reported hash back here.
        zigDepsHash = "sha256-O4+b9IpGkTklHLoSrH8ICWMYOIdTAw8nhhjkLAL7Ufw=";
        zigDeps = pkgs.stdenv.mkDerivation {
          pname = "xattr_stream-zig-deps";
          inherit version;
          src = ./.;
          nativeBuildInputs = [ zig pkgs.cacert ];
          outputHashMode = "recursive";
          outputHashAlgo = "sha256";
          outputHash = zigDepsHash;
          buildPhase = ''
            export HOME=$TMPDIR
            export ZIG_GLOBAL_CACHE_DIR=$out
            export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
            zig build --fetch=all
          '';
          dontInstall = true;
          dontFixup = true;
        };

        # Zig needs writable cache dirs inside the sandbox; dependencies come
        # from zigDeps above.
        zigEnv = ''
          export HOME=$TMPDIR
          export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-global
          export ZIG_LOCAL_CACHE_DIR=$TMPDIR/zig-local
          mkdir -p $ZIG_GLOBAL_CACHE_DIR
          cp -r ${zigDeps}/. $ZIG_GLOBAL_CACHE_DIR/
          chmod -R u+w $ZIG_GLOBAL_CACHE_DIR
          ${pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isDarwin "unset NIX_CFLAGS_COMPILE NIX_LDFLAGS"}
        '';

        mkCheck = name: extraInputs: script: pkgs.stdenv.mkDerivation {
          name = "xattr_stream-${name}";
          inherit src;
          nativeBuildInputs = [ zig ] ++ extraInputs;
          dontConfigure = true;
          dontFixup = true;
          # The sandbox's seccomp filter refuses setxattr on every filesystem,
          # so attribute tests are told to expect that; without this they fail
          # (see test-unsupported-is-fatal). ./test and the native CI runners
          # run them for real.
          XS_EXPECT_UNSUPPORTED = "1";
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

        # The Rust implementation (rust/): CLI, static and shared library with
        # the same C ABI, and the shared header. `cargo test` runs in the
        # sandbox, where attribute tests are declared unsupported (below) and
        # the rest run.
        # The crate has no dependencies; the whole repository is the source
        # because a test reads tests/cli/fixtures/allbytes.pb.
        rust = pkgs.rustPlatform.buildRustPackage {
          pname = "xattr_stream-rs";
          inherit version src;
          cargoLock.lockFile = ./rust/Cargo.lock;
          cargoRoot = "rust";
          # The sandbox refuses setxattr; attribute tests are told to expect it.
          XS_EXPECT_UNSUPPORTED = "1";
          buildAndTestSubdir = "rust";
          postInstall = ''
            mkdir -p $out/lib $out/include
            for lib in libxattr_stream.a libxattr_stream${pkgs.stdenv.hostPlatform.extensions.sharedLibrary}; do
              found=$(find . -path "*/release/$lib" -not -path "*/deps/*" | head -n 1)
              test -n "$found" || { echo "missing $lib" >&2; exit 1; }
              cp "$found" $out/lib/
            done
            cp include/xattr_stream.h $out/include/
          '';
          meta = with pkgs.lib; {
            description = "Cross-platform binary-safe file attributes: Rust library (same C ABI) and CLI";
            license = licenses.mit;
            platforms = platforms.linux ++ platforms.darwin;
            mainProgram = "xattr-stream-rs";
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

        # The Rust implementation for every platform (PF), cross-compiled from
        # this host. Zig is the C compiler and linker for every target, through
        # cargo-zigbuild, so no per-target C toolchain or SDK is needed.
        rustTargets = {
          linux-amd64 = "x86_64-unknown-linux-musl";
          linux-arm64 = "aarch64-unknown-linux-musl";
          macos-amd64 = "x86_64-apple-darwin";
          macos-arm64 = "aarch64-apple-darwin";
          mswin-amd64 = "x86_64-pc-windows-gnu";
          mswin-arm64 = "aarch64-pc-windows-gnullvm";
        };
        rustCrossToolchain = rust-overlay.packages.${system}.rust.override {
          targets = builtins.attrValues rustTargets;
        };
        rustCross = pkgs.stdenv.mkDerivation {
          pname = "xattr_stream-rs-cross";
          inherit version src;
          nativeBuildInputs = [ rustCrossToolchain pkgs.cargo-zigbuild zig ];
          dontConfigure = true;
          dontFixup = true;
          buildPhase = ''
            export HOME=$TMPDIR CARGO_HOME=$TMPDIR/cargo
            export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-global ZIG_LOCAL_CACHE_DIR=$TMPDIR/zig-local
            ${pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isDarwin "unset NIX_CFLAGS_COMPILE NIX_LDFLAGS"}
            cd rust
            # Cross builds ship the CLI and the static library; the Zig cross
            # step already provides shared libraries for every platform. Cargo
            # builds all of a library's crate types whenever the binary needs
            # it, and cdylib cannot link for musl or (through Zig) macOS, so
            # this copy drops it.
            substituteInPlace Cargo.toml --replace-fail \
              'crate-type = ["rlib", "staticlib", "cdylib"]' 'crate-type = ["rlib", "staticlib"]'
            # Any diagnostic fails the build, except two known notices: Zig
            # ignoring rustc's -Wl,-O1, and cargo-zigbuild not finding xcrun
            # (Zig links macOS against its own libSystem stubs).
            build_quietly() {
              local log; log=$(cargo zigbuild --offline --frozen --release --quiet --color never --target "$1" 2>&1) || {
                printf '%s\n' "$log" >&2; return 1; }
              # Each diagnostic starts with a warning: or error: headline.
              local rest; rest=$(printf '%s\n' "$log" | grep -e '^warning' -e '^error' | grep -v -x -F \
                -e 'warning: linker stderr: ignoring deprecated linker optimization setting "1"' \
                -e 'warning: invoking `"xcrun" "--sdk" "macosx" "--show-sdk-path"` to find MacOSX.sdk failed: No such file or directory (os error 2)' \
                -e 'warning: `xattr_stream` (bin "xattr-stream-rs") generated 1 warning') || true
              if [ -n "$rest" ]; then printf 'unexpected diagnostics for %s:\n%s\n' "$1" "$log" >&2; return 1; fi
            }
            ${pkgs.lib.concatStrings (pkgs.lib.mapAttrsToList (pf: triple: ''
              build_quietly ${triple}
            '') rustTargets)}
          '';
          installPhase = ''
            ${pkgs.lib.concatStrings (pkgs.lib.mapAttrsToList (pf: triple: ''
              mkdir -p $out/${pf}/release/bin $out/${pf}/release/lib $out/${pf}/release/include
              for f in xattr-stream-rs xattr-stream-rs.exe libxattr_stream.a xattr_stream.lib libxattr_stream.so libxattr_stream.dylib xattr_stream.dll; do
                p=target/${triple}/release/$f
                test -f "$p" || continue
                case "$f" in xattr-stream-rs*) cp "$p" $out/${pf}/release/bin/ ;; *) cp "$p" $out/${pf}/release/lib/ ;; esac
              done
              cp ../include/xattr_stream.h $out/${pf}/release/include/
            '') rustTargets)}
          '';
        };
      in
      {
        packages = {
          default = native;
          inherit native cross rust;
          rust-cross = rustCross;
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

          # The Rust CLI through the same Bash suite (declared unsupported
          # inside the sandbox, which refuses setxattr; ./test runs it for real).
          test-rust-cli = mkCheck "test-rust-cli" [ pkgs.bashInteractive pkgs.coreutils pkgs.diffutils ] ''
            bash tests/cli/test_cli.sh ${rust}/bin/xattr-stream-rs
          '';

          # Cross-compilation must succeed for all six platforms (PF,
          # <OS>-<ARCH>) even though only the host can run them.
          test-cross = mkCheck "test-cross" [ ] ''
            zig build cross --prefix out
            for pf in linux-amd64 linux-arm64 macos-amd64 macos-arm64; do
              test -f out/$pf/ReleaseFast/bin/xattr-stream || { echo "missing CLI for $pf" >&2; exit 1; }
              test -f out/$pf/ReleaseFast/lib/libxattr_stream.a || { echo "missing static lib for $pf" >&2; exit 1; }
            done
            for pf in mswin-amd64 mswin-arm64; do
              test -f out/$pf/ReleaseFast/bin/xattr-stream.exe || { echo "missing CLI for $pf" >&2; exit 1; }
              test -f out/$pf/ReleaseFast/lib/xattr_stream.lib || { echo "missing static lib for $pf" >&2; exit 1; }
              test -f out/$pf/ReleaseFast/lib/xattr_stream.dll || { echo "missing DLL for $pf" >&2; exit 1; }
            done
          '';

          # The control behind XS_EXPECT_UNSUPPORTED: this sandbox refuses
          # setxattr everywhere (a seccomp filter, whatever the filesystem),
          # so without the declaration every suite must fail and say why.
          test-unsupported-is-fatal = mkCheck "test-unsupported-is-fatal" [ pkgs.bashInteractive pkgs.coreutils pkgs.diffutils pkgs.gnugrep pkgs.luajit pkgs.clang pkgs.rustc pkgs.cargo ] ''
            zig build
            unset XS_EXPECT_UNSUPPORTED
            must_fail() {
              local name="$1"; shift
              if "$@" >"$name.log" 2>&1; then
                echo "$name passed on a filesystem without attributes" >&2; cat "$name.log" >&2; exit 1
              fi
              grep -q "set XS_EXPECT_UNSUPPORTED=1" "$name.log" || {
                echo "$name failed for another reason" >&2; cat "$name.log" >&2; exit 1
              }
            }
            must_fail zig-tests zig build test
            must_fail cli bash tests/cli/test_cli.sh zig-out/bin/xattr-stream
            must_fail differential bash tests/cli/differential.sh zig-out/bin/xattr-stream zig-out/bin/xattr-stream
            clang -std=c99 -Izig-out/include -o consumer_c tests/consumers/c/consumer.c zig-out/lib/libxattr_stream.a
            must_fail consumer-c ./consumer_c
            rustc --edition 2021 -O -C link-arg=zig-out/lib/libxattr_stream.a -o consumer_rs tests/consumers/rust/consumer.rs
            must_fail consumer-rust ./consumer_rs
            must_fail consumer-luajit luajit tests/consumers/luajit/consumer.lua zig-out/lib/libxattr_stream.so
            must_fail consumer-zig sh -c 'cd tests/consumers/zig && zig build test'
            export CARGO_HOME=$TMPDIR/cargo CARGO_TARGET_DIR=$TMPDIR/cargo-target
            must_fail rust-tests cargo test --offline --release --manifest-path rust/Cargo.toml
          '';

          # The Rust implementation for all six platforms: each CLI's actual
          # file header names its OS and architecture, every platform has its
          # static library, and the Linux CLIs run (arm64 under qemu-user)
          # and report their own platform.
          test-rust-cross = mkCheck "test-rust-cross" [ pkgs.file pkgs.qemu-user ] ''
            check_header() {
              local f="$1" want="$2" got
              got=$(file -b "$f")
              case "$got" in *"$want"*) ;; *) echo "$f: expected '$want', file says '$got'" >&2; exit 1 ;; esac
            }
            r=${rustCross}
            check_header $r/linux-amd64/release/bin/xattr-stream-rs "ELF 64-bit LSB executable, x86-64"
            check_header $r/linux-amd64/release/bin/xattr-stream-rs "statically linked"
            check_header $r/linux-arm64/release/bin/xattr-stream-rs "ELF 64-bit LSB executable, ARM aarch64"
            check_header $r/linux-arm64/release/bin/xattr-stream-rs "statically linked"
            check_header $r/macos-amd64/release/bin/xattr-stream-rs "Mach-O 64-bit x86_64 executable"
            check_header $r/macos-arm64/release/bin/xattr-stream-rs "Mach-O 64-bit arm64 executable"
            check_header $r/mswin-amd64/release/bin/xattr-stream-rs.exe "PE32+ executable"
            check_header $r/mswin-amd64/release/bin/xattr-stream-rs.exe "(console), x86-64"
            check_header $r/mswin-arm64/release/bin/xattr-stream-rs.exe "PE32+ executable"
            check_header $r/mswin-arm64/release/bin/xattr-stream-rs.exe "(console), ARM64"
            for pf in linux-amd64 linux-arm64 macos-amd64 macos-arm64 mswin-amd64 mswin-arm64; do
              test -s $r/$pf/release/lib/libxattr_stream.a || { echo "missing static lib for $pf" >&2; exit 1; }
              test -f $r/$pf/release/include/xattr_stream.h || { echo "missing header for $pf" >&2; exit 1; }
            done
            about=$($r/linux-amd64/release/bin/xattr-stream-rs --about)
            case "$about" in *" for linux-amd64") ;; *) echo "linux-amd64 --about: $about" >&2; exit 1 ;; esac
            about=$(qemu-aarch64 $r/linux-arm64/release/bin/xattr-stream-rs --about)
            case "$about" in *" for linux-arm64") ;; *) echo "linux-arm64 --about: $about" >&2; exit 1 ;; esac
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
            rustc --edition 2021 -O -C link-arg=zig-out/lib/libxattr_stream.a -o consumer_rs tests/consumers/rust/consumer.rs
            ./consumer_rs
          '';
          test-consumer-luajit = mkCheck "test-consumer-luajit" [ pkgs.luajit ] ''
            zig build
            luajit tests/consumers/luajit/consumer.lua zig-out/lib/libxattr_stream${pkgs.stdenv.hostPlatform.extensions.sharedLibrary}
          '';
          # An outside flake's view: nixpkgs extended with our overlay, then
          # the C consumer built from nothing but pkg-config output against
          # the installed package (proves the .pc file, install layout, and
          # overlay together).
          test-overlay-pkgconfig =
            let
              opkgs = import nixpkgs { inherit system; overlays = [ self.overlays.default ]; };
            in
            opkgs.stdenv.mkDerivation {
              name = "xattr_stream-test-overlay-pkgconfig";
              src = ./tests/consumers/c;
              nativeBuildInputs = [ opkgs.pkg-config ];
              buildInputs = [ opkgs.xattr_stream ];
              dontConfigure = true;
              XS_EXPECT_UNSUPPORTED = "1";
              buildPhase = ''
                $CC -std=c99 -Wall -Wextra -Werror -pedantic -o consumer consumer.c \
                  $(pkg-config --cflags --libs xattr_stream)
                ./consumer
              '';
              installPhase = ''
                mkdir -p $out
                echo passed > $out/test-overlay-pkgconfig
              '';
            };
          test-consumer-zig = mkCheck "test-consumer-zig" [ ] ''
            cd tests/consumers/zig && zig build test
          '';
        };

        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            zig
            clang
            pkg-config
            jq
            luajit
            rustc
            cargo
            bashInteractive
            coreutils
            gnugrep
            diffutils
          ];
          shellHook = ''
            echo "xattr_stream dev shell (zig $(zig version))"
            echo "  ./build       host library + CLI, commands linked into bin/<PF>/"
            echo "  ./build-all   all six platforms, commands linked into bin/<PF>/"
            echo "  ./test        everything"
          '';
        };
      });
}
