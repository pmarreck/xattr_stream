# TERMINOLOGY

- **attribute**: a named sequence of bytes attached to a file or directory,
  separate from its contents. Called an extended attribute (xattr) on Linux
  and macOS; realized as an NTFS alternate data stream on Windows.
- **logical name**: the caller-facing, OS-independent attribute name. Rules
  are in `include/xattr_stream.h` and `src/names.zig`.
- **native name**: what the OS actually stores. Linux: `user.<logical>`;
  macOS and Windows: the logical name verbatim.
- **raw mode**: `--raw` / `XS_FLAG_RAW_NAMES`; native names pass through
  untouched, except hard OS limits and Windows path-injection characters.
- **reserved name**: a name the logical grammar refuses because the OS uses
  it: anything starting with `$` or `com.apple.`, and `Zone.Identifier`.
- **missing**: the path exists but the attribute does not (`XS_MISSING`).
  Distinct from an empty value, which is present with length zero.
- **unsupported**: the filesystem or OS cannot hold attributes at all
  (`XS_UNSUPPORTED`). Never evidence of tampering.
- **alternate data stream (ADS)**: NTFS mechanism addressing extra byte
  streams of a file as `path:name`. Chosen over NTFS extended attributes.
- **follow / nofollow**: whether a symlink path addresses its target
  (default) or the link itself (`--nofollow` / `XS_FLAG_NOFOLLOW`).
- **consumer**: a program in another language (C, Rust, LuaJIT, Zig) that
  links or loads the library; each has a smoke test under `tests/consumers/`.
- **APE**: Actually Portable Executable, the Cosmopolitan single-binary
  format the pre-rewrite C version shipped as; retired 2026-09-16.
