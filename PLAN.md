# PLAN

Open work in priority order. Retired items: docs/PLAN_LOG.md. Background,
limits and evidence: docs/plan_context/.

## Next

- [ ] Table rendering through tsv_to_ansi_table (approved by BDFN 2026-10-23; it has Zig and Rust libraries). Its library form is published at b5806ccd775112165e785b1eaae0c2da0f72b90e: Zig module `tsv_to_ansi_table`, C ABI `include/tsv_to_ansi_table.h` (`tsvat_render`, streaming `tsvat_create/push_row/finish`), utf8proc as a declared Zig dependency, docs/libraries.md. Before adopting, confirm it builds for all six PFs (it reports four cross targets) and in our Nix sandbox
- [ ] Assess using the printable_binary Rust crate instead of the embedded glyph table; tell its agent that build scripts must not reach outside their crate
- [ ] Windows: port the Bash CLI suite (Git Bash path rewriting, forbidden `|`, `\` separators) (context: docs/plan_context/platform_verification.md)
- [ ] macOS: a qualified write boundary for the build-script tests, which `./test` reports as NOT RUN there (Bubblewrap is Linux-only)
- [ ] `cargo zigbuild` in packages.rust-cross: Zig's libc sub-compilation still starts a clang per CPU (no job flag reaches it); it failed once with SystemResources under heavy host load before `zig build` was capped

## Recently done

- [x] Build convention adopted (BDFN, 2026-10-23): `CANONICAL_IMPL` (zig), `./build canonize IMPL`, `--all-impls`/`--all-plats`/`--all` with long spellings, product trees `<impl>-out/<PF>/[<VARIANT>/]<profile>` (Nix links under `.nix-out/zig|rust/`, cross packages now `<PF>/[musl/]…`), only the canonical CLI published as `bin/<PF>/xattr-stream`, products checked (CLI present; host `--about` PF and VARIANT) before any output link or entry moves; `./build-all` retired. Tests: `tests/build/test_build.sh` (329 checks, 78 disposable projects, recording fakes, 2.1 s in parallel) confined by vendored `scripts/run-isolated` after forbidden-write canaries; Nix checks `test-build-script`, `test-build-real` (real packages, both canonical choices) and `selector-outside-sources` (canonize rebuilds nothing). Real `./build --all` and `./build --debug --all-impls` run on linux-amd64. `zig build` in derivations capped at NIX_BUILD_CORES after flake check hit the daemon's 8192-task limit (done 2026-10-23 19:25 EDT)
- [x] `--about` ends `PF=<PF>` plus ` VARIANT=musl|gnu` on Linux (C: glibc macro; Rust: target_env), checked against the binary's ELF interpreter (done 2026-10-23 18:38 EDT)
- [x] Rust cross builds for all six platforms (`nix build .#rust-cross`, rust-overlay toolchain, Zig as linker via cargo-zigbuild); `./build-all` links `bin/<PF>/xattr-stream-rs`; `test-rust-cross` checks real file headers and runs both Linux CLIs (arm64 under qemu-user). nixpkgs updated 2025-12-11 → 2026-10-20 for cargo-zigbuild 0.23.4; full suite and flake check green after it (done 2026-10-23 14:43 EDT)
- [x] Windows conventions in both CLIs: CRLF text output on stdout and stderr (raw `get` bytes untouched; `load` takes CRLF), `/name`, `/name:value`, `/?` switches; `OS` env (linux|macos|mswin) selects them on any build, other values (Windows' own `Windows_NT`) keep the compiled platform; `--limit=N` spelling. `./test` runs the CLI suite and differential under OS=mswin too (349 tests each, 848 cases); C stdio text calls are routed through one CRLF writer by macro, Rust pins its stream helpers with a source test; Windows CI runs a native smoke check (done 2026-10-23 14:07 EDT)
- [x] Attribute tests (Zig, CLI suite, differential, all consumers, Rust) fail on a filesystem that refuses attributes unless XS_EXPECT_UNSUPPORTED=1 declares it; `./test` fails on a missing tool instead of skipping; Nix check `test-unsupported-is-fatal` proves all nine suites fail undeclared in the sandbox. Measured: the sandbox's seccomp filter refuses setxattr in /build, /tmp, $out and tmpfs /dev/shm alike. Removed the unreachable Dec 2025 `tests/test.sh` (done 2026-10-23 13:48 EDT)
- [x] Rust implementation verified natively on all six platforms by GitHub Actions run 39979476930 (824b713); counts in docs/plan_context/platform_verification.md (done 2026-10-23 11:45 EDT)
- [x] Zig walker: entries a listing reports as `.unknown` (no d_type: XFS without ftype, some network mounts) are resolved with lstat, so their directories are entered; Zig 0.16 maps DT_UNKNOWN to `.unknown`, which the walker had treated as a plain file (done 2026-10-23 11:40 EDT)
- [x] Debug builds of both CLIs print a yellow `DEBUG BUILD!` on stderr (silenced by a non-empty MUTE_DEBUG_STATUS); `./test` checks Debug and release builds of each (done 2026-10-23 11:31 EDT)
- [x] Rust implementation in `rust/` (core, same C ABI, CLI `xattr-stream-rs`, no crates): CLI suite 305/305, differential 834 cases with 0 mismatches (catches planted one-character bugs), C and LuaJIT consumers over the Rust library, `nix build .#rust` (done 2026-10-23 11:25 EDT)
- [x] Found by the port and fixed in the C CLI too: numeric options take plain digits (`--cols=-1` wrapped to 2^64-1 and table padding ran practically forever); `--limit 18446744073709551615` no longer hangs `put` (done 2026-10-23 11:10 EDT)
- [x] Platform names (PF, `<OS>-<ARCH>`) in `xs_target()`/`--about`; six-platform cross step into `<PF>/<profile>/`; `./build` and `./build-all` link commands into `bin/<PF>/`; `build_all` renamed `build-all`; CI matrix adds macos-amd64 and linux-amd64 (done 2026-10-23 10:42 EDT)
- [x] GitHub Actions native workflow green on macOS ARM, Linux ARM, Windows x64 and Windows ARM (done 2026-10-21 17:15 EDT, de53a03)
- [x] Portable value limit corrected from 4096 to 3916 bytes after measuring ext4 (4040 for a 1-byte name, 4008 for 36 bytes) (done 2026-10-21 17:10 EDT)
- [x] Signed-bundle assessment: custom attributes added before or after signing keep codesign --verify --deep --strict valid; identity and keychain deleted (done 2026-10-21 16:58 EDT)
- [x] Windows: readers never see a partial stream write (share-mode serialization with bounded retry); concurrency test 40/40 natively (done 2026-10-21 16:55 EDT)
- [x] Approved both: GitHub Actions on macOS ARM, Windows x64/ARM, Linux ARM; scoped throwaway signing identity on the Mac (decided 2026-10-21 16:47 EDT)
- [x] Git history kept as is; privacy rule applies to current and future content (decided 2026-10-21 16:47 EDT)
