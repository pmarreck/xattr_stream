# Platform verification evidence

Native runs on the project's existing development hosts, 2026-10-14, from a
fresh clone or copied build in a temporary directory, touching only test
fixtures.

## aarch64-macos (macOS 26.7.1, APFS)

`nix develop -c ./test` on a clean clone of `a1b5fcc`, then on the fixed tree:

- Zig tests: 97/97, writing real attributes on APFS.
- First run found three problems, all fixed:
  - The CLI suite assumed every filesystem accepts non-UTF-8 file names.
    APFS refuses them, so the `path_pb` fixture never existed. The suite now
    probes the filesystem and reports those checks as not applicable.
  - The Rust consumer asked for a static link, but rustc passes
    `-lxattr_stream`, and Apple's linker prefers the dylib when both exist.
    It now passes the archive by path with `-C link-arg`.
  - Linker warnings: the library was built for the running macOS (26.7.1)
    while the Nix toolchain links for 14.0. Native macOS builds now default
    to a 13.0 minimum. `./test` fails consumer builds that print any
    diagnostic, so this cannot regress silently.
- After the fixes: CLI 286 passed, 0 failed, 1 not applicable; all five
  consumers pass with no linker output.
- `limits .` prints 72057594037927935 (APFS reports a 56-bit size).

## x86_64-windows (Windows 10 22H2, NTFS)

Zig test executables cross-compiled with `zig test -target
x86_64-windows-gnu --test-no-exec` and run natively:

- Name policy (6/6) and dump format (5/5) pass.
- Core and FFI suites: 35/36 and 51/52. The walk tests failed at first
  because the fake directory tree compared paths with `/` while the walker
  joins with `\` on Windows; the fakes now treat both as separators.
- The concurrent writers-and-readers test saw a few hundred partial values
  per run: stream writes truncate and then write, so a reader could open
  the stream in between. Fixed 2026-10-21 by serializing with share modes
  (writers exclusive, readers share-read, bounded retry on sharing
  violations). Both binaries then passed 20 runs each.
- Zero-length streams and symlink resolution through `path:stream` pass.
- `limits .` prints -1 (no portable query), as designed.

The Bash CLI suite under Git for Windows ran 231 passed, 56 failed. The
failures come from the harness and from Windows output conventions, not
from wrong attribute data:

- Git Bash rewrites `/tmp/...` arguments to `C:/Users/...`, so expected
  paths differ.
- Windows forbids `|` in file names, so one fixture cannot exist.
- Recursive listings print paths with `\`, the platform separator.
- Listings end lines with CRLF because stdout is in text mode. Making all
  text output LF would match Linux and macOS and keep dumps portable.

## Signed macOS bundles (2026-10-21)

On the macOS 26 host, in a temporary directory: a self-signed code-signing
identity in a temporary keychain file (the login keychain was untouched and
the search list restored), and test bundles built from a copy of
`/usr/bin/true`. Both were deleted afterward.

- Custom attributes added after signing, on the bundle directory, the
  executable and Info.plist, including a binary value, leave
  `codesign --verify --deep --strict` valid.
- Attributes present before signing are preserved by `codesign`, and the
  signature verifies.
- Removing an attribute keeps the signature valid, and the signed executable
  runs with an attribute on it.
- Only `com.apple.*` attributes such as FinderInfo count as signing
  "detritus"; the logical name grammar already refuses that namespace.

## ext4 single-block budget (2026-10-21)

Measured with `setfattr` on a GitHub ARM Linux runner (ext4, 4 KiB blocks,
256-byte inodes, no `ea_inode`): the largest value accepted as a file's only
attribute was 4040 bytes for `user.k` and `user.kk`, and 4008 bytes for a
36-character name. Both match `4044 - round_up4(name length)`. The portable
limit is therefore 3916 bytes, not 4096: a 4096-byte value fails with
ENOSPC, which the library reports as `XS_TOO_LARGE`.

## Windows ARM toolchain

Zig 0.16.0's aarch64-windows build crashes with an access violation
(0xC0000005) during `zig build`, before compiling project code; `zig version`
works. The ARM job therefore runs test executables cross-compiled on the x64
runner.

## Six platforms, both implementations (2026-10-23)

GitHub Actions run 39979476930 at 824b713, one hosted runner per platform
(PF). Unix runners run the whole `./test` in the dev shell; Windows runners
run the Zig tests and `cargo test --release` natively.

| PF | Filesystem | CLI suite, C and Rust CLI | Differential C vs Rust | Rust unit tests |
|---|---|---|---|---|
| linux-amd64 | ext4 | 305/305 each | 834 cases, 0 mismatches | 47 + 2 |
| linux-arm64 | ext4 | 305/305 each | 834 cases, 0 mismatches | 47 + 2 |
| macos-arm64 | APFS | 288 + 1 n/a each | 744 cases, 0 mismatches | 47 + 2 |
| macos-amd64 | APFS | 288 + 1 n/a each | 744 cases, 0 mismatches | 47 + 2 |
| mswin-amd64 | NTFS | not ported | not run | 48 + 2; Zig 99/99 |
| mswin-arm64 | NTFS | not ported | not run | 48 + 2; Zig 36, 52, 5 and 6 (cross-compiled executables) |

The differential runs fewer cases on APFS, which refuses non-UTF-8 file
names, so the generator leaves those paths out. The first Linux run failed
before any comparison: the seeded fixture gave some files more than ext4's
one 4 KiB block of attributes. The test now probes for large-value support
and keeps each file within the block where it is missing.

## Not run

- The Bash CLI suite on Windows (needs porting).
