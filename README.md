# xattr_stream

Cross-platform (Linux/macOS) streaming helper for extended attributes (xattrs).

## Goals

- CLI: `put|get|len|del|lst|limits`
- Binary-safe streaming: `put` reads from stdin; `get` writes to stdout.
- Two builds:
  - Native (`bin/xattr_stream`)
  - Cosmopolitan APE (`bin/xattr_stream_ape.com`) (built on Linux x86_64 host; intended to run on Linux + macOS)

## Development

- Run tests: `./test`
- Smoke test APE build: `./test_ape`
- Build native: `make native`
- Build APE (Linux x86_64 + cosmocc): `make ape`

## Notes

- `put` currently reads all of stdin into RAM before calling `setxattr` (v1 simplicity).
- `limits` prints a best-effort max xattr value size in bytes for the platform, or `-1` if unknown.
