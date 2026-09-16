# xattr_stream

[![Mechatron Prime CI](https://img.shields.io/endpoint?url=https%3A%2F%2Fthelio-nixos.tail66c90.ts.net%2Fbadges%2Fxattr_stream.json&style=for-the-badge)](https://thelio-nixos.tail66c90.ts.net/mechatron-prime/)

Cross-platform, binary-safe byte attributes on files and directories. One
library (Zig core behind a C ABI), one CLI, one name grammar, one error
taxonomy on Linux, macOS and Windows. Usable from C, Rust, Zig and LuaJIT.

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
xattr-stream --help | -h | --version | --about

  --nofollow      operate on a symlink itself, not its target
  --raw           native OS names (Linux user.x, macOS com.apple.x, NTFS any stream)
  --limit <n>     max value size in bytes for put/get (default 65536)
  --json          JSON on stdout for len/lst/limits, JSON errors on stderr
  --quiet         suppress warnings
  -r, --recurse   lst/dump: walk the tree below <path>, breadth-first
  -d, --depth <n> limit the walk to n levels (0 = <path> alone); implies -r
  --depth-first   walk depth-first (pre-order) instead
  --values        lst: show values; text, else printable-binary
  --hex           binary values as hex instead of printable-binary
  -w, --max-width <n>  cut displayed values after n chars: abcd…(10 bytes)
  --debug         report what a walk skipped (or set DEBUG)
  --color         force ANSI in listings; --no-color/--no-ansi/--simple never
```

On an interactive terminal, listings color attribute names bright orange
and values light blue (256-color ANSI). Piped output, JSON, `NO_COLOR`, and
`--no-color` get plain bytes; `--color` forces color into a pipe.

Recursive listings print tab-separated columns: `path`, `name`, and with
`--values` a type column (`text`, `pb` or `hex`) followed by the value. Text
means valid UTF-8 with no control characters other than TAB. Anything else,
including multi-line text, is rendered with
[printable-binary](https://github.com/pmarreck/printable-binary): one line
of UTF-8 in which every byte, including NUL and control characters, has a
visible glyph, and which converts back to the exact bytes with
`printable-binary -d`. It is linked in as a Zig dependency and consumed the
same way this library is, through its own C header. `--hex` switches binary
values to lowercase hex. Values print in full unless `-w`/`--max-width n`
is given, which cuts the displayed value after n characters (never inside a
UTF-8 glyph) and appends `…(N bytes)` with the raw length; JSON is never
cut. `get` is unaffected and always writes raw bytes. Children are
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
missing path is an error. `--json` produces an array of `{"path","name","text"|"pb"|"hex"}`
objects (no `path` when not recursing; plain name strings when neither
recursing nor showing values).

```sh
$ xattr-stream dump -r photos
photos	owner	text	Peter
photos/2026/beach.jpg	caption	text	sunny day
photos/2026/beach.jpg	thumb.bin	pb	·¯żŻ
$ xattr-stream --hex dump photos/2026/beach.jpg
caption	text	sunny day
thumb.bin	hex	0001feff
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
kernel ceiling: ext4 without the `ea_inode` feature keeps all of an inode's
attributes in roughly one 4 KiB block, btrfs allows about 16 KiB per value.
`limits` reports only the kernel figure, and a refused write surfaces as
`XS_TOO_LARGE`. The header exports `XS_PORTABLE_VALUE_LEN` (4096) as the
size that fits everywhere by default, and the CLI warns on stderr when a
value exceeds it (`--quiet` silences the warning). A value that grows between
the size query and the read is retried up to four times, then reported as
`XS_CHANGED`; a value that shrinks is returned at its actual length.

Atomicity: POSIX replaces one attribute atomically. On Windows a stream
write truncates then rewrites, so a concurrent reader can see a partial
value. Nothing spans multiple files or multiple attributes.

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

## Windows: streams, not EAs

Windows offers two candidates. NTFS extended attributes are capped at 64 KiB
per file, invisible to Explorer and most tools, and used in practice by WSL
and Cygwin for POSIX metadata. Alternate data streams hold any size, are
visible (`dir /r`, PowerShell `Get-Item -Stream`), survive NTFS-to-NTFS
copies, and are what Windows itself uses for per-file metadata
(`Zone.Identifier`). Streams were chosen. Names are validated before they
reach `CreateFileW`, so `:`, `\` and `/` can never turn a name into a path.

## Build and test

```sh
./build        # nix build, ReleaseFast, mirrors into zig-out/
./build_all    # all five targets into zig-out/cross/<triple>/
./test         # Zig tests, CLI suite, and C/Rust/LuaJIT/Zig consumers
nix flake check
```

Direct use of the toolchain inside `nix develop`: `zig build`, `zig build
test`, `zig build cross`.

Dependencies are declared in two places that must agree: `build.zig.zon`
pins `printable_binary` by URL and content hash for Zig, and `flake.nix`
fetches the same tree into a fixed-output derivation (`zigDepsHash`) so the
sandboxed Nix builds need no network. When `build.zig.zon` changes, set
`zigDepsHash` to `pkgs.lib.fakeHash`, run `nix build`, and copy the hash it
reports.

## Platform verification

Cross-compiling proves the code builds for a target, not that it runs
there. Status as of 2026-09-15:

| Target | Compiles | Runtime suite |
|---|---|---|
| x86_64-linux | yes | passes (Thelio, ZFS) |
| aarch64-linux | yes | not run |
| aarch64-macos | yes | not run |
| x86_64-windows | yes | not run |
| aarch64-windows | yes | not run |

Sandboxed Nix checks cannot exercise attribute I/O at all: Nix's build
sandbox installs a seccomp rule that makes `setxattr` fail with ENOTSUP,
because attributes are not representable in the store's NAR format. Inside
`nix flake check` the integration tests, the CLI suite and the consumers
therefore detect `XS_UNSUPPORTED` on their probe and report SKIP; what CI
proves is compilation for all targets, the pure name and packing logic, and
the skip path. Real attribute I/O is verified by `./test`, which runs in the
dev shell outside the sandbox.

Unverified items that need a real machine: macOS `pathconf` limit
reporting, Windows zero-length stream persistence, Windows symlink
resolution through `path:stream`, and custom xattrs on signed macOS app
bundles (see PLAN.md).

## Why Zig

The previous implementation was about 900 lines of C, roughly 60% of it
hand-rolled Cosmopolitan syscall shims for Linux and XNU, with no library
API and Windows returning ENOSYS. Adding Windows would have meant a third
shim set and a second toolchain. Zig 0.16 cross-compiles all five targets
from one host, links libSystem and kernel32 without SDKs, and gives an
in-process unit test tier the Bash suite could not. The C CLI is kept
deliberately: it can only reach the core through the header, which keeps
the public ABI exercised on every build. The Cosmopolitan APE single binary
is gone; its purpose, one easy cross-platform executable for attributes, is
now served by the per-target static binaries from `./build_all`.

MIT License.
