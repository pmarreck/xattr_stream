# PLAN

Open work in priority order. Retired items: docs/PLAN_LOG.md. Background,
limits and blockers: docs/plan_context/architecture_and_limits.md.

## Blocked on hardware Peter would have to provide

- [ ] Runtime verification on aarch64 Linux, macOS, Windows (context: docs/plan_context/architecture_and_limits.md)
- [ ] macOS signed-app xattr assessment: Mac, isolated artifacts, throwaway signing identity (context: docs/plan_context/architecture_and_limits.md)

## Deferred until Peter says it matters

- [ ] Encoding detection beyond UTF-8 via uchardetz; the --utf8 type column is ready for it

## Recently done

- [x] Delete bin/xattr_stream_ape.com (Peter's call, 2026-09-16 10:30 EDT; copy in ~/.Trash); commit AGENTS.md symlink + jj_cheatsheet removal
- [x] Binary values via printable_binary (Peter's call, 2026-09-16 11:50 EDT): Zig dependency pinned in build.zig.zon + flake zigDeps FOD; the C CLI links its static lib through its own header; `--hex` keeps hex; fixture from the independent LuaJIT implementation (12:00 EDT)
- [x] Colors: names bright orange, values light blue on a tty only (2026-09-16 11:55 EDT)
- [x] Dangling symlinks skipped in walks; `--debug`/DEBUG reports them (2026-09-16 12:10 EDT)
- [x] Output formats (Peter, 2026-09-16 12:29 EDT): --tsv/--csv/--table/--md, --cols widths, left-ellipsis paths, --utf8 type column utf8|pb|hex, names and values through printable-binary in delimited formats (done 2026-09-16 12:45 EDT, 02ff47d)
- [x] Migrate PLAN.md to the planning-work format; record blockers (done 2026-09-28 23:20 EDT)
