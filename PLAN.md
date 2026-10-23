# PLAN

Open work in priority order. Retired items: docs/PLAN_LOG.md. Background,
limits and evidence: docs/plan_context/.

## Next

- [ ] Rust implementation: confirm the native CI runs (macOS ARM/Intel, Linux ARM/x64 through `./test`; Windows x64/ARM through `cargo test`)
- [ ] Rust cross builds for all six platforms in `./build-all` (needs Rust standard libraries for the other targets in the flake, e.g. a rust-overlay toolchain)
- [ ] Windows: port the Bash CLI suite (Git Bash path rewriting, forbidden `|`, `\` separators) and decide LF-only text output (context: docs/plan_context/platform_verification.md)

## Recently done

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
