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
- Remaining failure: the concurrent writers-and-readers test sees a few
  hundred partial values per run. Windows stream writes truncate and then
  write, so a reader can open the stream in between. This is the documented
  limit, now measured. Fix options to evaluate: write a temporary stream and
  rename it over the target, or serialize readers and writers with share
  modes and bounded retries.
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

## Not run

- aarch64-linux and aarch64-windows: no such host was online.
- Signed macOS app bundles: needs a throwaway signing identity, which the
  standing host access does not cover.
