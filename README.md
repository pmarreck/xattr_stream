# xattr_stream

Cross-platform (Linux/macOS) streaming helper for extended attributes (xattrs).

## Goals

- CLI: `put|get|len|del|lst`
- Binary-safe streaming: `put` reads from stdin; `get` writes to stdout.
- Two builds:
  - Native (`bin/xattr_stream`)
  - Cosmopolitan APE (`bin/xattr_stream_ape.com`) (Linux x86_64 host only)

## Development

- Run tests: `./test`
- Build native: `make native`
- Build APE (Linux x86_64 + cosmocc): `make ape`

