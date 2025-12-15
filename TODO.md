# TODO (handoff directives)

## Scope

Implement `xattr_stream` as a tiny, dependency-light helper for streaming xattrs.

## CLI

- `xattr_stream put <path> <xattr_name>`: stdin → set xattr (overwrite).
- `xattr_stream get <path> <xattr_name>`: read xattr → stdout (binary).
- `xattr_stream len <path> <xattr_name>`: prints length in bytes, or `-1` if missing.
- `xattr_stream del <path> <xattr_name>`: delete xattr.
- `xattr_stream lst <path>`: list xattr names, one per line.

Options (suggested):

- `--nofollow`: operate on symlink itself (`l*` xattr functions where available).
- `--help`, `--version`

## Requirements / constraints

- Linux + macOS supported from the same C source via `#ifdef` shims:
  - Linux: `setxattr/getxattr/listxattr/removexattr` (+ `l*` variants).
  - macOS: `setxattr/getxattr/listxattr/removexattr` with (position, options) args (+ `l*` variants).
- Must be binary-safe (no text-mode munging).
- For large values: stream from stdin in chunks; do not assume values fit in memory if avoidable.
  - OK to read stdin fully into RAM for v1 if tests cover only small sizes; note in README if so.
- Avoid temp files; if unavoidable, use `mktemp --tmpdir`.

## Build / packaging

- Keep `flake.nix` pinned cosmocc (like `../printable-binary`).
- Provide `make native` and `make ape` (APE build only on Linux x86_64).
- Ensure `./test` is the single entry point for unit tests.

## Testing (TDD)

Follow strict TDD (write failing test first; run; then minimal code to pass).

Suggested early tests:

1. `--help` prints usage + commands, exit 0.
2. `len` on missing xattr prints `-1`.
3. `put` then `len` reflects byte count.
4. `put` then `get` round-trips bytes (include NUL bytes).
5. `del` removes it; `lst` lists expected names.

