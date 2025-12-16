# Plan

- [x] CLI implements `put|get|len|del|lst|limits` (and `set` alias for `put`)
- [x] `--nofollow` supported (uses `l*` xattr calls)
- [x] `--help` and `--version` supported
- [ ] Linux + macOS supported via `#ifdef` shims
- [x] Unit tests cover round-trip + listing + delete
- [ ] `make native` and `make ape` work (APE on Linux x86_64)
