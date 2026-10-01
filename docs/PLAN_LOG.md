# PLAN log

Completed PLAN.md items retired by plan-retire, oldest retirement first.

## Retired 2026-09-28

- [x] [Done] Acknowledge Einstein's note with a durable reply (23:15 EDT)
- [x] [Done] Decide Zig rewrite vs C extraction and record why (23:20 EDT)
- [x] [Done] Scaffold build.zig, build.zig.zon, flake.nix (zig-overlay 0.16.0), ./build, ./build_all, ./test (23:30 EDT)
- [x] [Done] Name policy as set classifiers: accept set, reject set with reasons, bijection, raw mode, Windows injection chars (23:12 EDT)
- [x] [Done] Error taxonomy + per-OS mapping; XS_* codes frozen in header (23:25 EDT)
- [x] [Done] Linux adapter (raw syscalls), macOS adapter (libSystem externs), Windows adapter (NTFS ADS via kernel32 externs); all five targets cross-compile, Windows/macOS analyzed via --test-no-exec (23:26 EDT)
- [x] [Done] C ABI + header with ownership rules; FFI tests (23:31 EDT)
- [x] [Done] C CLI preserving put|set|get|len|del|lst|list|limits, --nofollow, plus --raw, --limit, --json, --about; 110 Bash assertions (23:31 EDT)
- [x] [Done] Integration tests: all 256 bytes, empty, directories, overwrite, list/remove, invalid names, NotFound, TooLarge (VFS 64 KiB), getInto, symlink policy, rename vs replace, raw names, 8-thread concurrency, grow/shrink race via fake adapters, sorted listing (23:33 EDT)
- [x] [Done] Consumers: C (clang, -pedantic), Rust (rustc, static), LuaJIT (ffi, shared lib), Zig (path dependency) all pass on Linux (23:31 EDT)
- [x] [Done] Nix packages default + cross; checks for tests, CLI, cross, consumers
- [x] [Done] .mechatron-prime/targets written from `nix flake show`
- [x] [Open] Commit the known-good state as 2ed4ca8 and push yolo (23:40 EDT)
- [x] [Open] Mechatron Prime: webhook already existed; 2ed4ca8 PASS in 3m16s (23:43 EDT)
- [x] [Open] Default value bound = 64 KiB on every OS (min of the OS maxima)
- [x] [Open] Naming: auto-prefix on Linux only; caller-supplied `user.` is refused with a Linux-specific reason; CLI warns above 4096 bytes (11:05 EDT)
- [x] [Open] Final durable report to Einstein; original note Trashed (23:42 EDT)
- [x] [Open] Listing with values: `lst --values` / `dump`; printable single-line UTF-8 as text, else hex; JSON mirrors it; `get` stays raw (11:35 EDT)
- [x] [Open] Output format review by Peter (columns: [path] name [type value])
- [x] [Open] Colors: names bright orange, values light blue on a tty only (11:55 EDT)
- [x] [Open] Dangling symlinks skipped in walks; `--debug`/DEBUG reports them

## Retired 2026-10-01

- [x] [Recently done] Delete bin/xattr_stream_ape.com (Peter's call, 2026-09-16 10:30 EDT; copy in ~/.Trash); commit AGENTS.md symlink + jj_cheatsheet removal
- [x] [Recently done] Binary values via printable_binary (Peter's call, 2026-09-16 11:50 EDT): Zig dependency pinned in build.zig.zon + flake zigDeps FOD; the C CLI links its static lib through its own header; `--hex` keeps hex; fixture from the independent LuaJIT implementation (12:00 EDT)
