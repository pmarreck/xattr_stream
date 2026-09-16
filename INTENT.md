# INTENT

## Purpose and users

xattr_stream is a small, embeddable library and CLI for storing and reading
binary-safe byte attributes on files and directories, with one name grammar
and one error taxonomy on Linux, macOS and Windows. It exists so that
applications written in C, Rust, Zig and LuaJIT can attach per-file metadata
without each reimplementing three OS interfaces and their error quirks.

Origin: the tool started (December 2025) as a Linux/macOS C helper that
streamed xattr values through stdin/stdout for Peter's own scripts. On
2026-09-15 Peter asked, through the orchestrator agent Einstein, to make it a
general-purpose cross-platform attribute library and to consider a Zig 0.16
rewrite. The rewrite was chosen; the reasoning is in README "Why Zig".

## Desired outcomes

- One C ABI (`include/xattr_stream.h`) with byte-length payloads, explicit
  ownership (`xs_buffer_free`), and stable numbered status codes.
- A portable logical name grammar so the same name works on every OS, with a
  raw escape hatch for native names.
- Distinguishable failures: missing attribute, empty value, unsupported
  filesystem, read-only, permission, too large, path not found, invalid name.
  An unsupported filesystem is never evidence of tampering.
- Binary-safe put/get/len/del/lst on files and directories, with explicit
  symlink policy and bounded value sizes.
- The CLI (`xattr-stream`) exercises only the public C ABI.
- Consumers in C, Rust, Zig and LuaJIT compile and pass a round trip in CI.
- Cross-compiles for x86_64/aarch64 Linux, aarch64 macOS, x86_64/aarch64
  Windows from one toolchain.

## Scope and non-goals

In scope: per-attribute get/set/remove/list/size, name normalization,
per-OS adapters, the CLI, packaging via Nix, documentation.

Explicitly out of scope (owner boundary, 2026-09-15): licensing, secret
storage, home-directory persistence, authentication keys, anti-tamper
policy, and two-copy reconciliation. Those are application policy and must
stay in the consuming application. The library permits caller-selected
paths and nothing more.

Not provided: cross-file atomicity (POSIX replaces one attribute
atomically; nothing spans files), true streaming of values larger than RAM
(values are bounded and buffered), and NTFS extended attributes (alternate
data streams were chosen; see README).

## Constraints and tradeoffs

- Zig 0.16 only; no upgrade to 0.17 as part of this work.
- MIT license retained.
- Logical names are capped at 127 bytes because macOS is the strictest
  target; the Windows character blacklist applies on every OS so a name that
  works anywhere works everywhere.
- Linux logical names live in the `user.` namespace only; other namespaces
  are reachable through raw mode.
- The Cosmopolitan APE single binary is no longer built. The old binary
  remains tracked as a legacy artifact pending Peter's decision.

## How success is verified

- `./test` runs Zig unit and integration tests against real OS calls on
  isolated temp fixtures, the Bash CLI suite, and all four consumers.
- `nix flake check` runs the same as sandboxed checks plus the five-target
  cross-compile.
- Runtime verification is honest per platform: Linux x86_64 verified on the
  Thelio; macOS and Windows are cross-compiled and compile-checked but not
  yet executed (see README "Platform verification").

## Open questions

- Whether to remove the legacy APE binary from the repository.
- macOS: behavior of custom xattrs on signed app bundles across copy, update
  and codesign verification. Needs a Mac and isolated artifacts; pending.
- Windows: whether zero-length named streams persist, and how symlink
  resolution interacts with `path:stream` opens. Needs a Windows runtime.
- macOS: whether `pathconf(_PC_XATTR_SIZE_BITS)` reports a value on APFS.

See TERMINOLOGY.md for definitions and PLAN.md for execution state.
