# PLAN

Open work in priority order. Retired items: docs/PLAN_LOG.md. Background,
limits and blockers: docs/plan_context/architecture_and_limits.md.

## Active (Peter, 2026-10-01)

- [x] pkg-config file (relocatable via pcfiledir) installed with the library; ./test and the test-overlay-pkgconfig check build the C consumer through it (done 2026-10-01 17:20 EDT)
- [x] Flake overlay `overlays.default` providing pkgs.xattr_stream (done 2026-10-01 17:20 EDT)
- [ ] Printable-binary output preserves literal spaces in every text format
- [ ] `dump --json`: one JSON object per file, values printable-binary, names verbatim, invalid-UTF-8 paths under `path_pb` (context: docs/plan_context/json_dump_and_load.md)
- [ ] `load` verb restores a JSON dump byte-exact; refuses absolute paths and `..` unless `--allow-unsafe-paths`; `--root DIR` rebases (context: docs/plan_context/json_dump_and_load.md)

## Blocked on hardware Peter would have to provide

- [ ] Runtime verification on aarch64 Linux, macOS, Windows (context: docs/plan_context/architecture_and_limits.md)
- [ ] macOS signed-app xattr assessment: Mac, isolated artifacts, throwaway signing identity (context: docs/plan_context/architecture_and_limits.md)

## Deferred until Peter says it matters

- [ ] Encoding detection beyond UTF-8 via uchardetz; the --utf8 type column is ready for it

## Recently done

- [x] Colors: names bright orange, values light blue on a tty only (2026-09-16 11:55 EDT)
- [x] Dangling symlinks skipped in walks; `--debug`/DEBUG reports them (2026-09-16 12:10 EDT)
- [x] Output formats (Peter, 2026-09-16 12:29 EDT): --tsv/--csv/--table/--md, --cols widths, left-ellipsis paths, --utf8 type column utf8|pb|hex, names and values through printable-binary in delimited formats (done 2026-09-16 12:45 EDT, 02ff47d)
- [x] Migrate PLAN.md to the planning-work format; record blockers (done 2026-09-28 23:20 EDT)
