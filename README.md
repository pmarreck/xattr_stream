# xattr_stream

[![Mechatron Prime CI](https://img.shields.io/endpoint?url=https%3A%2F%2Fthelio-nixos.tail66c90.ts.net%2Fbadges%2Fxattr_stream.json&style=for-the-badge)](https://thelio-nixos.tail66c90.ts.net/mechatron-prime/)

Cross-platform, binary-safe byte attributes on files and directories. One
library (Zig core behind a C ABI), one CLI, one name grammar, one error
taxonomy on Linux, macOS and Windows. Usable from C, Rust, Zig and LuaJIT.
A second, pure-Rust implementation in `rust/` exports the same C ABI and
ships the same CLI as `xattr-stream-rs` (see "Rust implementation").

| OS | Mechanism | Native form of logical name `k` |
|---|---|---|
| Linux | extended attributes (`user.*`) | `user.k` |
| macOS | extended attributes | `k` |
| Windows | NTFS alternate data streams | `file:k` |

## CLI

```
xattr-stream [options] put|set <path> <name>   value from stdin
xattr-stream [options] get <path> <name>       value to stdout
xattr-stream [options] len <path> <name>       byte length, or -1 if missing
xattr-stream [options] del <path> <name>       delete (no error if missing)
xattr-stream [options] lst|list <path>         names, one per line, sorted
xattr-stream [options] dmp|dump <path>         names and values (lst --values)
xattr-stream [options] lim|limits [<path>]     max value bytes on that filesystem, or -1
xattr-stream [options] load [<file>|-|@stdin]  restore a --json dump (stdin by default)
xattr-stream --help | -h | --version | --about

  --nofollow      operate on a symlink itself, not its target
  --raw           native OS names (Linux user.x, macOS com.apple.x, NTFS any stream)
  --limit <n>     max value size in bytes for put/get (default 65536)
  --json          JSON on stdout for len/lst/limits, JSON errors on stderr
  --quiet         suppress warnings
  --root <dir>    load: resolve relative dump paths against <dir>
  --allow-unsafe-paths  load: accept absolute paths and .. components
  -r, --recurse   lst/dump: walk the tree below <path>, breadth-first
  -d, --depth <n> limit the walk to n levels (0 = <path> alone); implies -r
  --depth-first   walk depth-first (pre-order) instead
  --values        lst: show values through printable-binary
  --utf8          printable single-line UTF-8 values verbatim, plus a type column
  --hex           values as lowercase hex instead of printable-binary
  --tsv           tab-separated rows, no header (default)
  --csv           comma-separated rows with a header
  --table         ASCII table (widths: path 48, name 24, type 4, value 40)
  --md, --markdown  Markdown table with the same widths
  --cols <a,b,..> column widths in display order; implies --table unless --md
  -w, --max-width <n>  TSV: cut displayed values after n chars: abcd…(10 bytes)
  --debug         report what a walk skipped (or set DEBUG)
  --color         force ANSI in listings; --no-color/--no-ansi/--simple never
```

On an interactive terminal, listings color attribute names bright orange
and values light blue (256-color ANSI). Piped output, JSON, `NO_COLOR`, and
`--no-color` get plain bytes; `--color` forces color into a pipe.

Listings are rows of `[path] name [type] value`. The path column appears
when recursing, the value with `--values` or `dump`, the type only with
`--utf8`. Every value is rendered with
[printable-binary](https://github.com/pmarreck/printable-binary) by
default: one line of UTF-8 in which every byte except the space, including
NUL, control characters and delimiters, has a visible lookalike glyph
(`multi¶line`, `a٫b∣c`). Spaces stay literal, so `sunny day` reads as
written. It converts back to the exact bytes with `printable-binary -d`.
It is linked in as a Zig dependency and consumed the
same way this library is, through its own C header. Multi-byte text comes
out as per-byte glyphs in that mode; `--utf8` shows values that are valid
single-line UTF-8 verbatim instead and adds the type column, which says
`utf8`, `pb` or `hex` (never a vague "text", leaving room for detected
encodings later). `--hex` uses lowercase hex in place of printable-binary.
`get` is unaffected and always writes raw bytes.

Four row formats:
- `--tsv` (default): tab-separated, no header. `-w`/`--max-width n` cuts a
  displayed value after n characters, never inside a glyph, and appends
  `…(N bytes)` with the raw length.
- `--csv`: comma-separated with a header. Names and values always go
  through printable-binary (so no delimiter can occur in them), paths are
  quoted per RFC 4180 when they need it; `--utf8` is ignored here.
- `--table`: an ASCII frame with fixed column widths, default path 48,
  name 24, type 4, value 40. Paths truncate on the left so the end of the
  path is always visible; other cells truncate on the right. Names go
  through printable-binary and any `|` left in a cell becomes `∣`.
- `--md`/`--markdown`: the same cells as a Markdown table, with `|`
  escaped as `\|`.
- `--cols a,b,...` sets the widths of the present columns in display order
  (0 = no truncation, no padding) and implies `--table` unless `--md` is
  given. JSON ignores all of these. Children are
visited in bytewise order and listed as soon as their directory is read,
which keeps the window for files deleted mid-walk to microseconds and the
queue proportional to directories rather than files; symlinks are listed
(per the follow policy) but never entered, so link loops cannot recurse. A subdirectory that cannot be
read is reported as a warning and the walk continues, with exit code 1 at
the end. Entries that cannot be found by the time their attributes are
read, dangling symlinks and files deleted mid-walk (browser caches churn
like this), have nothing to list and are skipped silently; `--debug` (or a
`DEBUG` environment variable set to anything but `0`) reports each skip on
stderr without changing the exit code. The root path is exempt: naming a
missing path is an error.

With `--json`, `dump` (or `lst --values`) writes one JSON object per file,
one per line, in walk order. Files without attributes produce no line:

```
{"path":"docs/notes.md","xattrs":{"owner":"alice","state":"draft, v2"}}
{"path_pb":"jd⁄cafȚ","xattrs":{"k":"v"}}
```

Values are always printable-binary with literal spaces, whatever `--utf8`,
`--hex` or `-w` say, so the format alone says how to decode them. Names are
written as they are. A path that is not valid UTF-8 (possible on Linux)
cannot appear in JSON, so it is written printable-binary encoded under
`path_pb` instead of `path`; raw names that are not UTF-8 go under
`xattrs_pb` the same way, and so do paths and names in JSON warnings and
errors. Names-only listings stay a JSON array: plain name strings for one
file, `{"path","name"}` objects when recursing.

`load` reads that format back and writes each value's original bytes:

```sh
(cd photos && xattr-stream --json dump -r .) > photos.xattrs.ndjson
xattr-stream load --root /restore/photos photos.xattrs.ndjson
```

It sets the listed attributes and leaves any others on the file alone. It
never creates files, so a path that does not exist is reported. Relative
paths resolve against `--root`, or the current directory without it.
Absolute paths and paths with a `..` component are refused unless
`--allow-unsafe-paths` is given, so a doctored dump cannot write outside the
target tree. Both POSIX and Windows forms (`C:`, `\\server`) count, on every
OS. With the flag, absolute paths are used as written. Names under
`xattrs_pb` are usually raw native names and need `--raw`. A malformed line,
refused path or failed write is reported with its line number, the rest of
the dump still loads, and the exit code is 1.

```sh
$ xattr-stream dump -r photos
photos	owner	alice
photos/2026/beach.jpg	caption	sunny day
photos/2026/beach.jpg	thumb.bin	·¯żŻ
$ xattr-stream --utf8 dump photos/2026/beach.jpg
caption	utf8	sunny day
thumb.bin	pb	·¯żŻ
$ xattr-stream --table --cols 20,10,12 dump -r photos
+----------------------+------------+--------------+
| path                 | name       | value        |
+----------------------+------------+--------------+
| photos               | owner      | alice        |
| …otos/2026/beach.jpg | caption    | sunny day    |
| …otos/2026/beach.jpg | thumb.bin  | ·¯żŻ         |
+----------------------+------------+--------------+
```

Options go anywhere; later options override earlier ones; `--` ends options.
Exit codes: 0 ok, 1 error, 2 usage, 3 unsupported filesystem, 4 missing
attribute, 5 permission or read-only, 6 too large, 7 path not found,
8 invalid name or path. Every error names its status on stderr, for example
`XS_MISSING`, along with the raw OS error number.

```sh
printf 'hello' | xattr-stream put notes.txt llc.mecha.probe
xattr-stream len notes.txt llc.mecha.probe      # 5
xattr-stream get notes.txt llc.mecha.probe      # hello
xattr-stream --json lst notes.txt               # ["llc.mecha.probe"]
```

## Names

Logical names (the default) work identically on every OS: 1 to 127 bytes of
valid UTF-8, no control characters, none of `/ \ : * ? " < > |`, no leading or
trailing space, no trailing dot, not starting with `$` or `com.apple.`, and
not `Zone.Identifier` (case-insensitive). Linux stores them under `user.`;
macOS and Windows verbatim. Because Linux requires that namespace (the
kernel answers ENOTSUP for any name without a recognized prefix, and only
`user.` is writable without privilege) and the library adds it for you, a
name that already starts with `user.` is refused with an explanation rather
than stored as `user.user.<name>`. The mapping is a bijection, so listings
show exactly the names a caller could address. Native names outside the
grammar (other Linux namespaces, Apple's reserved attributes, NTFS `$`
streams) are hidden from logical listings and reachable only with `--raw`.
`xs_validate_name` reports the exact reason for any refusal.

The 127-byte cap comes from macOS, the strictest target. The character
blacklist is Windows's, applied everywhere so a portable name is portable.
Windows stream names are case-insensitive: two logical names that differ
only in case collide there.

## Errors

`XS_MISSING` (attribute absent), `XS_UNSUPPORTED` (filesystem cannot hold
attributes; not evidence of tampering), `XS_READ_ONLY`, `XS_PERMISSION`,
`XS_TOO_LARGE`, `XS_NOT_FOUND` (path), `XS_INVALID_NAME`, `XS_INVALID_PATH`,
`XS_CHANGED` (value kept changing during read), `XS_BUFFER_TOO_SMALL`,
`XS_OUT_OF_MEMORY`, `XS_IO`, `XS_INVALID_ARGUMENT`. An empty value is present
with length zero, never `XS_MISSING`. `xs_last_os_error()` gives the errno
or Win32 code behind the most recent failure on the calling thread.

## Sizes and races

Values are read and written whole; this is not a streaming API. Every
operation is bounded by `max_value_len`. The default is 64 KiB on every OS:
the smallest OS ceiling across targets (Linux's kernel limit,
`XATTR_SIZE_MAX`), chosen so a value accepted on one platform is accepted on
all of them. macOS and NTFS allow far more; raise the bound per call only
when you knowingly target those alone. Larger writes are refused and larger
reads fail before allocating. Some Linux filesystems stop well below the
kernel ceiling: ext4 without the `ea_inode` feature keeps all of a file's
attributes in one 4 KiB block, and btrfs allows about 16 KiB per value.
`limits` reports only the kernel figure, and a refused write surfaces as
`XS_TOO_LARGE`. An ext4 block holds a 32-byte header, a 4-byte end marker,
and per attribute a 16-byte entry plus the name padded to 4 bytes, so a
file's only attribute can hold `4044 - round_up4(name length)` bytes. On
ext4 that measured 4040 bytes for a 1-byte name and 4008 for a 36-byte one.
The header exports `XS_PORTABLE_VALUE_LEN` (3916), the value budget next to
the longest valid name. Several attributes on one file share the block. The
CLI warns on stderr when a value exceeds 3916 bytes (`--quiet` silences the
warning). A value that grows between
the size query and the read is retried up to four times, then reported as
`XS_CHANGED`; a value that shrinks is returned at its actual length.

Atomicity: POSIX replaces one attribute atomically. On Windows a stream
write truncates then rewrites, so the adapter serializes access with NTFS
share modes: a writer holds the stream exclusively, a reader shares it only
with other readers, and an open or delete that meets a sharing violation
retries for up to about 2 s before reporting `XS_IO`. Readers therefore see
the old value or the new one, never a partial write. A program outside this
library that holds the stream open can still stall it. Nothing spans
multiple files or multiple attributes.

## Symlinks, directories, rename

Directories carry attributes like files. By default a symlink path addresses
its target; `--nofollow` addresses the link. Linux refuses `user.*`
attributes on symlinks (`XS_PERMISSION`); macOS allows them. Attributes
follow a file through `rename`; a fresh file renamed over the old one brings
only its own attributes.

## Library

Public header: `include/xattr_stream.h`. Build products: `libxattr_stream.a`
(C, Rust), `libxattr_stream.so` / `.dylib` / `xattr_stream.dll` (LuaJIT and
other dynamic loaders), and the `xattr_stream` Zig module for sibling Zig
projects (`tests/consumers/zig` shows the path dependency).

```c
xs_buffer b = {0};
if (xs_get(path, strlen(path), "k", 1, NULL, &b) == XS_OK) {
    fwrite(b.data, 1, b.len, stdout);
    xs_buffer_free(&b);
}
```

All payloads are `(pointer, byte length)`. NULL is legal only with length
zero. Buffers returned by `xs_get` and `xs_list` are released with
`xs_buffer_free`, never `free()`. Working examples for each language are the
consumer tests under `tests/consumers/`.

### From another project

The install tree carries `lib/pkgconfig/xattr_stream.pc`. Its prefix is
relative to the file itself, so it works from `zig-out/`, the Nix store, or a
copied tree:

```sh
cc app.c $(PKG_CONFIG_PATH=/path/to/prefix/lib/pkgconfig pkg-config --cflags --libs xattr_stream)
```

`-lxattr_stream` picks the shared library when both are installed. For a
static link, name `$(pkg-config --variable=libdir xattr_stream)/libxattr_stream.a`
directly and add `pkg-config --libs --static`'s private libraries.

From another flake, add the overlay and use `pkgs.xattr_stream`:

```nix
inputs.xattr_stream.url = "github:pmarreck/xattr_stream";
# ...
pkgs = import nixpkgs { inherit system; overlays = [ xattr_stream.overlays.default ]; };
# then: nativeBuildInputs = [ pkgs.pkg-config ]; buildInputs = [ pkgs.xattr_stream ];
```

The `test-overlay-pkgconfig` check does exactly this with the C consumer.
Zig projects should use a `build.zig.zon` dependency and the `xattr_stream`
module instead.

## Rust implementation

`rust/` is a port of the whole project to Rust with no third-party crates:
the core (names, values, listing, dump parsing, tree walking, OS adapters
for Linux, macOS and Windows), the C ABI from `include/xattr_stream.h`
(static and shared library), and the CLI as `xattr-stream-rs`. It behaves
identically, byte for byte, and these checks hold it to that:

- The Bash CLI suite (`tests/cli/test_cli.sh`) runs unchanged against both
  CLIs.
- `tests/cli/differential.sh` builds a seeded fixture tree (random names,
  text and binary values, non-UTF-8 and control-character file names where
  the filesystem allows them, symlinks), runs about 830 commands through both
  CLIs, every listing format and error path among them, plus 400 fuzzed
  `load` lines, and requires identical stdout, stderr, exit code and
  resulting attributes. Planting a one-character bug in the Rust code makes
  it fail.
- The C and LuaJIT consumers link against the Rust library.
- Rust unit tests port the Zig ones: name sets, dump-line sets, walk order
  on a fake tree, the read-retry logic on a fake adapter, and real-attribute
  tests on private temporary directories. printable-binary is checked in
  both directions for every byte and byte pair, and against a fixture
  written by the independent LuaJIT encoder.

```sh
cd rust && cargo build --release   # target/release/xattr-stream-rs, libxattr_stream.{a,so,dylib}
nix build .#rust                   # bin/, lib/, include/ as one tree
```

The one intended difference is `--about`, which says "Rust implementation".
Where the two disagreed, the C CLI was fixed as well: numeric options now
take plain decimal digits (`strtoull` had accepted `-1` for `--cols` and
wrapped it to a width that made table padding run practically forever), and
`--limit 18446744073709551615` no longer hangs `put`.

## Windows: streams, not EAs

Windows offers two candidates. NTFS extended attributes are capped at 64 KiB
per file, invisible to Explorer and most tools, and used in practice by WSL
and Cygwin for POSIX metadata. Alternate data streams hold any size, are
visible (`dir /r`, PowerShell `Get-Item -Stream`), survive NTFS-to-NTFS
copies, and are what Windows itself uses for per-file metadata
(`Zone.Identifier`). Streams were chosen. Names are validated before they
reach `CreateFileW`, so `:`, `\` and `/` can never turn a name into a path.

## Build and test

Platforms are named `<OS>-<ARCH>` (PF): OS is `linux`, `macos` or `mswin`,
ARCH is `amd64` or `arm64`, giving six platforms. Commands are linked into
`bin/<PF>/`, so a PATH entry for `bin/linux-amd64` never picks up a Mac
binary copied alongside it.

```sh
./build        # host platform, ReleaseFast via nix build; bin/<PF>/xattr-stream
./build-all    # all six platforms, cross-compiled; bin/<PF>/ for each
./test         # Zig tests, CLI suite, C/Rust/LuaJIT/Zig consumers, pkg-config consumer
nix flake check
```

`./build --debug` and `./build --test` build Debug and ReleaseSafe through
the dev shell into `zig-out/<PF>/<profile>/`. Product trees (`bin/`, `lib/`,
`include/`) stay whole: Nix outputs are kept at `.nix-out/<PF>/ReleaseFast`
and `.nix-out/cross/<PF>/ReleaseFast`, and `bin/<PF>/` holds only links to
them. Without Nix: `zig build --prefix zig-out/<PF>/ReleaseFast`, `zig build
test`, and `zig build cross --prefix <dir>`.

Dependencies are declared in two places that must agree: `build.zig.zon`
pins `printable_binary` by URL and content hash for Zig, and `flake.nix`
fetches the same tree into a fixed-output derivation (`zigDepsHash`) so the
sandboxed Nix builds need no network. When `build.zig.zon` changes, set
`zigDepsHash` to `pkgs.lib.fakeHash`, run `nix build`, and copy the hash it
reports.

## Platform verification

Cross-compiling proves the code builds for a platform, not that it runs
there. Mechatron Prime CI builds all six platforms but can only run tests
on linux-amd64, inside the Nix sandbox. The GitHub Actions workflow in
`.github/workflows/native.yml` reruns the suites natively on every platform
on every push. Results (details in
docs/plan_context/platform_verification.md):

| Platform | Compiles | Zig tests (real attribute I/O) | CLI suite | Consumers |
|---|---|---|---|---|
| linux-amd64 (ZFS) | yes | 97/97 | 302/302 | C, Rust, LuaJIT, Zig, pkg-config |
| linux-amd64 (ext4) | yes | per push, GitHub Actions | per push | per push |
| linux-arm64 (ext4) | yes | per push | per push | per push |
| macos-arm64 26 (APFS) | yes | 97/97 | 286 pass, 1 n/a | C, Rust, LuaJIT, Zig, pkg-config |
| macos-amd64 (APFS) | yes | per push | per push | per push |
| mswin-amd64 10 (NTFS) | yes | 99/99 (concurrency test green in 40 of 40 runs) | not yet ported to Windows | not run |
| mswin-arm64 | yes | per push, cross-compiled test executables run natively (Zig 0.16.0's own ARM64 Windows compiler crashes) | not yet ported | not run |

Sandboxed Nix checks cannot exercise attribute I/O at all: Nix's build
sandbox installs a seccomp rule that makes `setxattr` fail with ENOTSUP,
because attributes are not representable in the store's NAR format. This
holds on every filesystem the sandbox can write (measured: the build
directory, `/tmp`, `$out` and a tmpfs `/dev/shm`), so no scratch location
helps.

Every attribute test fails on a filesystem that refuses attributes, unless
the run declares that case with `XS_EXPECT_UNSUPPORTED=1`. The sandboxed
checks declare it: there the Zig tests skip their attribute cases visibly,
and the CLI suite, differential and consumers stop after the probe confirms
`XS_UNSUPPORTED`. The check `test-unsupported-is-fatal` runs each of those
suites in the sandbox without the declaration and requires every one to
fail and name the variable. What Nix CI proves is compilation for all
targets, the pure name and packing logic, and that control. Real attribute
I/O is verified by `./test`, which runs in the dev shell outside the
sandbox, and by the native GitHub Actions runners.

Verified natively: macOS `pathconf` limit reporting (APFS reports a
56-bit size), Windows zero-length streams, Windows symlink resolution
through `path:stream`, and custom attributes on signed macOS bundles, which
leave `codesign --verify --deep --strict` valid. Still unverified: the Bash
CLI suite on Windows (see PLAN.md).

## Why Zig

The previous implementation was about 900 lines of C, roughly 60% of it
hand-rolled Cosmopolitan syscall shims for Linux and XNU, with no library
API and Windows returning ENOSYS. Adding Windows would have meant a third
shim set and a second toolchain. Zig 0.16 cross-compiles all six platforms
from one host, links libSystem and kernel32 without SDKs, and gives an
in-process unit test tier the Bash suite could not. The C CLI is kept
deliberately: it can only reach the core through the header, which keeps
the public ABI exercised on every build. The Cosmopolitan APE single binary
is gone; its purpose, one easy cross-platform executable for attributes, is
now served by the per-platform static binaries from `./build-all`.

MIT License.
