# JSON dump and load

Decisions by Peter, 2026-09-30 and 2026-10-01.

## Format

Newline-delimited JSON, one object per file, streamed in walk order:

    {"path":"docs/notes.md","xattrs":{"state":"draft, v2"}}
    {"path_pb":"cafȚ.txt","xattrs":{"k":"v"}}

- Values are always printable-binary with literal spaces preserved. No type
  tag: the format defines the encoding.
- Names are written verbatim. The name grammar guarantees valid UTF-8 without
  control characters. Names admitted by `--raw` may be arbitrary bytes and are
  written printable-binary encoded inside an `xattrs_pb` object instead.
- Paths that are valid UTF-8 are written verbatim under `path`. Paths that
  are not valid UTF-8 are printable-binary encoded under `path_pb`.
- Files with no attributes are omitted.

## Why no tag in storage

The file keeps its real bytes. A prefix or a sidecar attribute would change
what other programs read (macOS quarantine, Wine security descriptors), write
to user files, and spend ext4's ~4 KiB per-inode budget.

## Load

`load [FILE|-]` reads that stream and writes decoded bytes back.

- Refuses absolute paths and any `..` component unless
  `--allow-unsafe-paths` is given, so a doctored dump cannot write outside
  the target tree.
- `--root DIR` resolves relative paths against DIR instead of the current
  directory.
- Overwrites existing attributes of the same name; leaves other attributes
  alone.
