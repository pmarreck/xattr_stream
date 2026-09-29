# Architecture, known limits and open questions

Moved out of PLAN.md on 2026-09-28 so the plan stays a checklist.

## Mandate

Peter via Einstein, 2026-09-15: make xattr_stream a small cross-platform
byte-attribute library plus CLI, usable from C, Rust, Zig and LuaJIT, with
Windows support, normalized names, distinguishable errors, and a
self-contained test suite. Purpose and boundaries live in INTENT.md.

## Architecture decision (2026-09-15 23:20 EDT)

Rewrite in Zig 0.16; reasoning in README "Why Zig". Layout:

- `src/names.zig`: pure name policy
- `src/xattr_stream.zig`: port, error taxonomy, race handling
- `src/{linux,darwin,windows}.zig`: adapters
- `src/walk.zig`: generic directory walker and the std.Io.Dir lister
- `src/ffi.zig`: the only `export fn xs_*`
- `include/xattr_stream.h`: the public C ABI
- `src/xattr_stream_cli.c`: C CLI over the header, all I/O
- `tests/cli/`: Bash CLI suite
- `tests/consumers/{c,rust,luajit,zig}`: FFI consumers

## Known limits (documented in README)

- Nix sandbox seccomp returns ENOTSUP for setxattr, so sandboxed checks skip
  attribute I/O; `./test` in the dev shell is the runtime oracle.
- Windows stream writes are truncate-then-write, not atomic for readers.
- No cross-file or cross-attribute atomicity; values are buffered whole and
  bounded by `--limit` / `max_value_len`.

## Curiosity pokes

- Windows: zero-length named stream persistence and `link:stream` symlink
  resolution are unverified assumptions in the adapter comments.
- macOS: `_PC_XATTR_SIZE_BITS` (26) may return -1 on APFS; `limits` then
  prints -1 rather than probing (probing writes to the filesystem).
- The concurrency test asserts whole values under 8 writers; it cannot
  distinguish a torn read on Windows where writes are not atomic.

## Blocked items (as of 2026-09-28 23:20 EDT)

- Runtime verification on aarch64 Linux, macOS and Windows: cross-compiles
  are green in CI, but no machine of those kinds is reachable from Thelio.
  Unblocks when Peter provides a Mac, an aarch64 Linux host, or a Windows box
  (or a CI runner for any of them).
- macOS signed-app xattr assessment: needs a Mac, isolated artifacts and a
  throwaway signing identity. Same blocker.
- Encoding detection beyond UTF-8 (uchardetz): conditional on legacy text
  values ever mattering to Peter; the `--utf8` type column already has room
  for a third label. Not started on purpose.

## Design note, not a work item

Caching a probed per-filesystem value limit keyed by filesystem identity with
invalidation, modelled on `../os_counters`. Peter asked for the design
discussion only (2026-09-16); it is recorded in the transcript and must not be
built without a new request.
