# PLAN

Open work in priority order. Retired items: docs/PLAN_LOG.md. Background,
limits and evidence: docs/plan_context/.

## Next

- [ ] Debug builds of the CLI announce "DEBUG BUILD" in yellow on stderr unless MUTE_DEBUG_STATUS is set (`./build --debug` help already claims this; nothing implements it yet)
- [ ] Rust implementation (pure Rust, no crates): library plus `xattr-stream-rs` CLI with byte-identical output; oracles are the existing Bash CLI suite run against it and a seeded differential test against the Zig/C CLI
- [ ] Windows: port the Bash CLI suite (Git Bash path rewriting, forbidden `|`, `\` separators) and decide LF-only text output (context: docs/plan_context/platform_verification.md)

## Recently done

- [x] Platform names (PF, `<OS>-<ARCH>`) in `xs_target()`/`--about`; six-platform cross step into `<PF>/<profile>/`; `./build` and `./build-all` link commands into `bin/<PF>/`; `build_all` renamed `build-all`; CI matrix adds macos-amd64 and linux-amd64 (done 2026-10-23 10:42 EDT)
- [x] GitHub Actions native workflow green on macOS ARM, Linux ARM, Windows x64 and Windows ARM (done 2026-10-21 17:15 EDT, de53a03)
- [x] Portable value limit corrected from 4096 to 3916 bytes after measuring ext4 (4040 for a 1-byte name, 4008 for 36 bytes) (done 2026-10-21 17:10 EDT)
- [x] Signed-bundle assessment: custom attributes added before or after signing keep codesign --verify --deep --strict valid; identity and keychain deleted (done 2026-10-21 16:58 EDT)
- [x] Windows: readers never see a partial stream write (share-mode serialization with bounded retry); concurrency test 40/40 natively (done 2026-10-21 16:55 EDT)
- [x] Approved both: GitHub Actions on macOS ARM, Windows x64/ARM, Linux ARM; scoped throwaway signing identity on the Mac (decided 2026-10-21 16:47 EDT)
- [x] Git history kept as is; privacy rule applies to current and future content (decided 2026-10-21 16:47 EDT)
