# PLAN

Open work in priority order. Retired items: docs/PLAN_LOG.md. Background,
limits and blockers: docs/plan_context/architecture_and_limits.md.

## Active (2026-10-01)


## Awaiting owner decisions (walking brief, queued 2026-10-14)

- [x] Git history kept as is; privacy rule applies to current and future content (decided 2026-10-21 16:47 EDT)
- [x] Approved both: GitHub Actions on macOS ARM, Windows x64/ARM, Linux ARM; scoped throwaway signing identity on the Mac (decided 2026-10-21 16:47 EDT)

## Next

- [ ] GitHub Actions workflow running the Zig tests on macos ARM, windows x64, windows ARM and ubuntu ARM runners on every push
- [x] Signed-bundle assessment: custom attributes added before or after signing keep codesign --verify --deep --strict valid; identity and keychain deleted (done 2026-10-21 16:58 EDT)
- [x] Portable value limit corrected from 4096 to 3916 bytes after measuring ext4 (4040 for a 1-byte name, 4008 for 36 bytes) (done 2026-10-21 17:10 EDT)
- [x] Windows: readers never see a partial stream write (share-mode serialization with bounded retry); concurrency test 40/40 natively (done 2026-10-21 16:55 EDT)
- [ ] Windows: port the Bash CLI suite (Git Bash path rewriting, forbidden `|`, `\` separators) and decide LF-only text output (context: docs/plan_context/platform_verification.md)

## Blocked on test hardware

- [ ] Runtime verification on aarch64 Linux and aarch64 Windows: no such host online (context: docs/plan_context/platform_verification.md)

## Recently done

- [x] Native macOS arm64 run: fixed non-UTF-8 fixture assumption, Rust dylib link, deployment-target warnings; Windows x64 Zig tests run, walk fakes fixed (done 2026-10-14 15:00 EDT)
