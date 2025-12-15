# Plan

- [ ] CLI implements `put|get|len|del|lst|limits`
- [ ] `--nofollow` supported (uses `l*` xattr calls)
- [ ] `--help` and `--version` supported
- [ ] Linux + macOS supported via `#ifdef` shims
- [ ] Unit tests cover round-trip + listing + delete
- [ ] `make native` and `make ape` work (APE on Linux x86_64)
