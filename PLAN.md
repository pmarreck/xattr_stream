# PLAN

Mandate (Peter via Einstein, 2026-09-15): make xattr_stream a small
cross-platform byte-attribute library plus CLI, usable from C, Rust, Zig and
LuaJIT, with Windows support, normalized names, distinguishable errors, and
a self-contained test suite. Purpose and boundaries live in INTENT.md.

## Architecture decision (2026-09-15 23:20 EDT)

Rewrite in Zig 0.16; reasoning in README "Why Zig". Layout:
`src/names.zig` (pure name policy), `src/xattr_stream.zig` (port + error
taxonomy + race handling), `src/{linux,darwin,windows}.zig` (adapters),
`src/ffi.zig` (the only `export fn xs_*`), `include/xattr_stream.h`,
`src/xattr_stream_cli.c` (C CLI over the header), `tests/cli/` (Bash),
`tests/consumers/{c,rust,luajit,zig}`.

## Done

- [x] Acknowledge Einstein's note with a durable reply (23:15 EDT)
- [x] Decide Zig rewrite vs C extraction and record why (23:20 EDT)
- [x] Scaffold build.zig, build.zig.zon, flake.nix (zig-overlay 0.16.0),
      ./build, ./build_all, ./test (23:30 EDT)
- [x] Name policy as set classifiers: accept set, reject set with reasons,
      bijection, raw mode, Windows injection chars (23:12 EDT)
- [x] Error taxonomy + per-OS mapping; XS_* codes frozen in header (23:25 EDT)
- [x] Linux adapter (raw syscalls), macOS adapter (libSystem externs),
      Windows adapter (NTFS ADS via kernel32 externs); all five targets
      cross-compile, Windows/macOS analyzed via --test-no-exec (23:26 EDT)
- [x] C ABI + header with ownership rules; FFI tests (23:31 EDT)
- [x] C CLI preserving put|set|get|len|del|lst|list|limits, --nofollow,
      plus --raw, --limit, --json, --about; 110 Bash assertions (23:31 EDT)
- [x] Integration tests: all 256 bytes, empty, directories, overwrite,
      list/remove, invalid names, NotFound, TooLarge (VFS 64 KiB), getInto,
      symlink policy, rename vs replace, raw names, 8-thread concurrency,
      grow/shrink race via fake adapters, sorted listing (23:33 EDT)
- [x] Consumers: C (clang, -pedantic), Rust (rustc, static), LuaJIT (ffi,
      shared lib), Zig (path dependency) all pass on Linux (23:31 EDT)
- [x] Nix packages default + cross; checks for tests, CLI, cross, consumers
- [x] INTENT.md, TERMINOLOGY.md, README rewritten; TODO/PROJECT_PLAN/
      NEXT_STEPS/AGENTS_previous/Makefile/test_ape/verify_ape/C source
      retired to ~/.Trash/xattr_stream-retired-2026-09-15 and git history
- [x] .mechatron-prime/targets written from `nix flake show`

## Open

- [x] Commit the known-good state as 2ed4ca8 and push yolo (23:40 EDT)
- [x] Mechatron Prime: webhook already existed; 2ed4ca8 PASS in 3m16s (23:43 EDT)
- [ ] Runtime verification on aarch64 Linux, macOS, Windows (no machine here)
- [ ] macOS signed-app xattr assessment: needs a Mac, isolated artifacts, and
      a throwaway signing identity; report as pending
- [x] Delete bin/xattr_stream_ape.com (Peter's call, 2026-09-16 10:30 EDT;
      copy in ~/.Trash); commit AGENTS.md symlink + jj_cheatsheet removal
- [x] Default value bound = 64 KiB on every OS (min of the OS maxima)
- [x] Naming: auto-prefix on Linux only; caller-supplied `user.` is refused
      with a Linux-specific reason; CLI warns above 4096 bytes (11:05 EDT)
- [x] Final durable report to Einstein; original note Trashed (23:42 EDT)
- [x] Recursive listing (Peter, 2026-09-16 11:24 EDT): `-r/--recurse`,
      `-d N`/`-d=N`/`--depth N`/`--depth=N` (depth implies recurse),
      breadth-first default, `--depth-first`; walker in the Zig core over
      std.Io.Dir, exposed as `xs_walk`, unreadable dirs warn and continue
      (11:35 EDT)
- [x] Listing with values: `lst --values` / `dump`; printable single-line
      UTF-8 as text, else hex; JSON mirrors it; `get` stays raw (11:35 EDT)
- [ ] Output format review by Peter (columns: [path] name [text|hex value])
- [ ] Encoding detection beyond UTF-8 (uchardetz) if legacy text values
      ever matter; hex is the fallback until then
- [ ] Design only, not building: caching a probed per-filesystem limit
      keyed by filesystem identity with invalidation (see os_counters)

## Known limits (documented in README)

- Nix sandbox seccomp returns ENOTSUP for setxattr, so sandboxed checks skip
  attribute I/O; `./test` in the dev shell is the runtime oracle.
- Windows stream writes are truncate-then-write, not atomic for readers.
- No cross-file or cross-attribute atomicity; values are buffered whole and
  bounded by --limit / max_value_len.

## Curiosity pokes

- Windows: zero-length named stream persistence and `link:stream` symlink
  resolution are unverified assumptions in the adapter comments.
- macOS: `_PC_XATTR_SIZE_BITS` (26) may return -1 on APFS; `limits` then
  prints -1 rather than probing (probing writes to the filesystem).
- The concurrency test asserts whole values under 8 writers; it cannot
  distinguish a torn read on Windows where writes are not atomic.
