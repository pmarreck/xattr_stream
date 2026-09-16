#!/usr/bin/env bash
# CLI surface tests for xattr-stream. Driven against a compiled binary given
# as argv[1]. No `set -e`: commands under test are expected to fail; the
# harness asserts on exit codes explicitly and accumulates failures.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/capture.bash
source "$ROOT/tests/lib/capture.bash"

BIN="${1:-}"
if [[ -z "$BIN" || ! -x "$BIN" ]]; then
	echo "usage: test_cli.sh <path/to/xattr-stream>" >&2
	exit 2
fi
BIN="$(cd "$(dirname "$BIN")" && pwd)/$(basename "$BIN")"

failures=0
passes=0
current=""

pass() { passes=$((passes + 1)); }
fail() {
	failures=$((failures + 1))
	printf 'FAIL [%s]: %s\n' "$current" "$*" >&2
}
assert_rc() { [[ "$rc" -eq "$1" ]] && pass || fail "expected rc=$1 got rc=$rc (stderr=$err)"; }
assert_out() { [[ "$out" == "$1" ]] && pass || fail "expected stdout '$1' got '$out'"; }
assert_err_has() { [[ "$err" == *"$1"* ]] && pass || fail "expected stderr to contain '$1' got '$err'"; }
assert_err_empty() { [[ -z "$err" ]] && pass || fail "expected empty stderr got '$err'"; }

os_name() { uname -s; }

# Native spelling of a logical name on this OS (mirrors names.zig for --raw tests).
native_name() {
	case "$(os_name)" in
		Linux) printf 'user.%s' "$1" ;;
		*) printf '%s' "$1" ;;
	esac
}

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/xattr_stream_cli.XXXXXX")"
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT

allbytes="$tmpdir/allbytes.bin"
for i in $(seq 0 255); do printf "\\$(printf '%03o' "$i")"; done >"$allbytes"

new_file() {
	local f="$tmpdir/$1"
	: >"$f"
	printf '%s' "$f"
}

# Probe once: if this filesystem cannot hold attributes at all, the suite
# cannot verify anything meaningful here and says so loudly.
probe="$(new_file probe)"
out=""; err=""; rc=0
capture "$BIN" put "$probe" probe <<<"x"
if [[ "$rc" -eq 3 ]]; then
	echo "SKIP: filesystem at $tmpdir does not support attributes (XS_UNSUPPORTED)" >&2
	exit 0
fi

current="help"
out=""; err=""; rc=0; capture "$BIN" --help
assert_rc 0
for word in put get len del lst dump dmp limits lim --nofollow --raw --limit --json --quiet --recurse --depth --depth-first --values --debug --color --no-color --hex --max-width --about; do
	[[ "$out" == *"$word"* ]] && pass || fail "help missing '$word'"
done
out=""; err=""; rc=0; capture "$BIN" -h
assert_rc 0

current="version"
out=""; err=""; rc=0; capture "$BIN" --version
assert_rc 0
[[ "$out" =~ ^xattr-stream\ [0-9]+\.[0-9]+\.[0-9]+$ ]] && pass || fail "unexpected version line '$out'"

current="about"
out=""; err=""; rc=0; capture "$BIN" --about
assert_rc 0
[[ "$(printf '%s' "$out" | wc -l)" -eq 0 ]] && pass || fail "--about must be one line"
[[ "$out" == *"xattr-stream"* && "$out" =~ [0-9]+\.[0-9]+\.[0-9]+ ]] && pass || fail "--about missing name/version: '$out'"
[[ "$out" == *"linux"* || "$out" == *"macos"* || "$out" == *"windows"* ]] && pass || fail "--about missing platform: '$out'"
[[ "$out" == *"x86_64"* || "$out" == *"aarch64"* ]] && pass || fail "--about missing arch: '$out'"

current="usage errors"
out=""; err=""; rc=0; capture "$BIN"
assert_rc 2
assert_err_has "Usage"
out=""; err=""; rc=0; capture "$BIN" --bogus
assert_rc 2
out=""; err=""; rc=0; capture "$BIN" get onlyonearg
assert_rc 2
out=""; err=""; rc=0; capture "$BIN" frobnicate a b
assert_rc 2
out=""; err=""; rc=0; capture "$BIN" --limit notanumber len a b
assert_rc 2

current="len missing"
f="$(new_file f1)"
out=""; err=""; rc=0; capture "$BIN" len "$f" nope
assert_rc 0
assert_out "-1"
assert_err_empty

current="binary round trip"
f="$(new_file f2)"
out=""; err=""; rc=0; capture "$BIN" put "$f" llc.mecha.probe <"$allbytes"
assert_rc 0
assert_err_empty
out=""; err=""; rc=0; capture "$BIN" len "$f" llc.mecha.probe
assert_rc 0
assert_out "256"
"$BIN" get "$f" llc.mecha.probe >"$tmpdir/got.bin" 2>"$tmpdir/got.err"
[[ $? -eq 0 ]] && pass || fail "get rc"
cmp -s "$allbytes" "$tmpdir/got.bin" && pass || fail "get round-trip bytes differ"
[[ ! -s "$tmpdir/got.err" ]] && pass || fail "get wrote to stderr: $(cat "$tmpdir/got.err")"

current="set alias and overwrite"
out=""; err=""; rc=0; capture "$BIN" set "$f" llc.mecha.probe <<<"short"
assert_rc 0
out=""; err=""; rc=0; capture "$BIN" len "$f" llc.mecha.probe
assert_out "6"

current="empty value"
f="$(new_file f3)"
out=""; err=""; rc=0; capture "$BIN" put "$f" empty </dev/null
assert_rc 0
out=""; err=""; rc=0; capture "$BIN" len "$f" empty
assert_out "0"
out=""; err=""; rc=0; capture "$BIN" get "$f" empty
assert_rc 0
assert_out ""
out=""; err=""; rc=0; capture "$BIN" lst "$f"
assert_out "empty"

current="get missing"
out=""; err=""; rc=0; capture "$BIN" get "$f" nope
assert_rc 4
assert_err_has "XS_MISSING"
assert_out ""

current="del and lst"
f="$(new_file f4)"
for n in alpha beta.gamma delta; do "$BIN" put "$f" "$n" <<<"$n" || fail "put $n"; done
out=""; err=""; rc=0; capture "$BIN" lst "$f"
assert_rc 0
[[ "$(printf '%s\n' "$out" | sort | tr '\n' ' ')" == "alpha beta.gamma delta " ]] && pass || fail "lst mismatch: '$out'"
out=""; err=""; rc=0; capture "$BIN" list "$f"
assert_rc 0
out=""; err=""; rc=0; capture "$BIN" del "$f" beta.gamma
assert_rc 0
out=""; err=""; rc=0; capture "$BIN" del "$f" beta.gamma
assert_rc 0
out=""; err=""; rc=0; capture "$BIN" lst "$f"
[[ "$out" != *"beta.gamma"* ]] && pass || fail "beta.gamma still listed"
out=""; err=""; rc=0; capture "$BIN" len "$f" beta.gamma
assert_out "-1"

current="json output"
out=""; err=""; rc=0; capture "$BIN" --json lst "$f"
assert_rc 0
assert_out '["alpha","delta"]'
out=""; err=""; rc=0; capture "$BIN" --json len "$f" alpha
assert_out '{"len":6}'
out=""; err=""; rc=0; capture "$BIN" --json len "$f" nope
assert_out '{"len":-1}'
out=""; err=""; rc=0; capture "$BIN" --json limits "$f"
[[ "$out" =~ ^\{\"max_value_bytes\":-?[0-9]+\}$ ]] && pass || fail "json limits: '$out'"
out=""; err=""; rc=0; capture "$BIN" --json get "$f" nope
assert_rc 4
[[ "$err" =~ ^\{\"status\":\"XS_MISSING\" ]] && pass || fail "json error: '$err'"
out=""; err=""; rc=0; capture "$BIN" --json lst "$(new_file f5)"
assert_out '[]'

current="invalid names"
missing_path="$tmpdir/does-not-exist"
for n in "a:b" "..\\x" '$DATA' "Zone.Identifier" "com.apple.quarantine" "trailing." ""; do
	out=""; err=""; rc=0; capture "$BIN" put "$missing_path" "$n" <<<"v"
	assert_rc 8
	assert_err_has "XS_INVALID_NAME"
	out=""; err=""; rc=0; capture "$BIN" len "$missing_path" "$n"
	assert_rc 8
done

current="user. prefix is reserved for Linux"
f="$(new_file f5b)"
out=""; err=""; rc=0; capture "$BIN" put "$f" user.foo <<<"v"
assert_rc 8
assert_err_has "XS_INVALID_NAME"
assert_err_has "Linux"
assert_err_has "user."
out=""; err=""; rc=0; capture "$BIN" --json len "$f" user.foo
assert_rc 8
[[ "$err" == *'"reason":"XS_NAME_LINUX_NAMESPACE"'* ]] && pass || fail "json error should carry the name rejection reason: '$err'"
out=""; err=""; rc=0; capture "$BIN" --raw put "$f" "$(native_name rawok)" <<<"v"
assert_rc 0

current="portability warning above 4096 bytes"
f="$(new_file f5c)"
head -c 4096 /dev/zero >"$tmpdir/exact4k"
head -c 4097 /dev/zero >"$tmpdir/over4k"
out=""; err=""; rc=0; capture "$BIN" put "$f" k <"$tmpdir/exact4k"
assert_rc 0
assert_err_empty
out=""; err=""; rc=0; capture "$BIN" put "$f" k <"$tmpdir/over4k"
assert_rc 0
assert_err_has "warning"
assert_err_has "4096"
out=""; err=""; rc=0; capture "$BIN" --quiet put "$f" k <"$tmpdir/over4k"
assert_rc 0
assert_err_empty
out=""; err=""; rc=0; capture "$BIN" --json put "$f" k <"$tmpdir/over4k"
assert_rc 0
[[ "$err" =~ ^\{\"warning\": ]] && pass || fail "json warning: '$err'"
out=""; err=""; rc=0; capture "$BIN" len "$f" k
assert_out "4097"

current="recursive listing"
tree="$tmpdir/tree"
mkdir -p "$tree/a/x" "$tree/b"
: >"$tree/a/x/deep"; : >"$tree/a/y"; : >"$tree/b/z"; : >"$tree/f1"
ln -s a "$tree/l"
printf 'r' | "$BIN" put "$tree" root.attr
printf 'A' | "$BIN" put "$tree/a" a.attr
"$BIN" put "$tree/a/x/deep" deep.attr <"$allbytes"
printf 'one' | "$BIN" put "$tree/f1" f1.attr
printf 'two' | "$BIN" put "$tree/f1" f1.other
"$BIN" put "$tree/b/z" z.attr </dev/null
bfs="$tree	root.attr
$tree/a	a.attr
$tree/f1	f1.attr
$tree/f1	f1.other
$tree/l	a.attr
$tree/b/z	z.attr
$tree/a/x/deep	deep.attr"
out=""; err=""; rc=0; capture "$BIN" lst -r "$tree"
assert_rc 0
assert_err_empty
assert_out "$bfs"
out=""; err=""; rc=0; capture "$BIN" --recurse lst "$tree"
assert_out "$bfs"
out=""; err=""; rc=0; capture "$BIN" lst -r --depth-first "$tree"
assert_out "$tree	root.attr
$tree/a	a.attr
$tree/a/x/deep	deep.attr
$tree/b/z	z.attr
$tree/f1	f1.attr
$tree/f1	f1.other
$tree/l	a.attr"
# --nofollow: the symlink's own (empty) attribute set, not its target's
out=""; err=""; rc=0; capture "$BIN" --nofollow lst -r "$tree"
[[ "$out" != *"$tree/l"* ]] && pass || fail "nofollow recursion should not list the link target's attributes"
# non-recursive output is unchanged
out=""; err=""; rc=0; capture "$BIN" lst "$tree/f1"
assert_out "f1.attr
f1.other"

current="depth limits"
d1="$tree	root.attr
$tree/a	a.attr
$tree/f1	f1.attr
$tree/f1	f1.other
$tree/l	a.attr"
for form in "-d 1" "-d=1" "--depth 1" "--depth=1"; do
	# shellcheck disable=SC2086
	out=""; err=""; rc=0; capture "$BIN" lst $form "$tree"
	assert_rc 0
	assert_out "$d1"
done
out=""; err=""; rc=0; capture "$BIN" lst -d 0 "$tree"
assert_out "$tree	root.attr"
out=""; err=""; rc=0; capture "$BIN" lst -d nope "$tree"
assert_rc 2

current="values: text or hex"
out=""; err=""; rc=0; capture "$BIN" lst --values -d 1 "$tree"
assert_out "$tree	root.attr	text	r
$tree/a	a.attr	text	A
$tree/f1	f1.attr	text	one
$tree/f1	f1.other	text	two
$tree/l	a.attr	text	A"
# Binary values render as printable-binary text (one line, no control chars,
# reversible with `printable-binary -d`). The fixture was produced by the
# independent LuaJIT printable-binary implementation, not by this program.
allpb="$(cat "$ROOT/tests/cli/fixtures/allbytes.pb")"
allhex="$(od -An -v -tx1 "$allbytes" | tr -d ' \n')"
out=""; err=""; rc=0; capture "$BIN" lst --values "$tree/a/x/deep"
assert_out "deep.attr	pb	$allpb"
out=""; err=""; rc=0; capture "$BIN" --hex lst --values "$tree/a/x/deep"
assert_out "deep.attr	hex	$allhex"
printf '\x00\x01\xfe\xff' | "$BIN" put "$tree/a/x/deep" small.bin
out=""; err=""; rc=0; capture "$BIN" dump "$tree/a/x/deep"
assert_out "deep.attr	pb	$allpb
small.bin	pb	·¯żŻ"
"$BIN" del "$tree/a/x/deep" small.bin
out=""; err=""; rc=0; capture "$BIN" lst --values "$tree/b/z"
assert_out "z.attr	text	"
out=""; err=""; rc=0; capture "$BIN" dump "$tree/f1"
assert_out "f1.attr	text	one
f1.other	text	two"
# Three-letter aliases, like put/get/len/del/lst.
out=""; err=""; rc=0; capture "$BIN" dmp "$tree/f1"
assert_out "f1.attr	text	one
f1.other	text	two"
out=""; err=""; rc=0; capture "$BIN" lim "$tree/f1"
assert_rc 0
[[ "$out" =~ ^-?[0-9]+$ ]] && pass || fail "lim alias: '$out'"
printf 'multi\nline' | "$BIN" put "$tree/f1" f1.multi
out=""; err=""; rc=0; capture "$BIN" dump "$tree/f1"
assert_out "f1.attr	text	one
f1.multi	pb	multi¶line
f1.other	text	two"
out=""; err=""; rc=0; capture "$BIN" --hex dump "$tree/f1"
assert_out "f1.attr	text	one
f1.multi	hex	6d756c74690a6c696e65
f1.other	text	two"
"$BIN" del "$tree/f1" f1.multi

current="recursive json"
out=""; err=""; rc=0; capture "$BIN" --json lst -d 1 "$tree"
assert_rc 0
assert_out "[{\"path\":\"$tree\",\"name\":\"root.attr\"},{\"path\":\"$tree/a\",\"name\":\"a.attr\"},{\"path\":\"$tree/f1\",\"name\":\"f1.attr\"},{\"path\":\"$tree/f1\",\"name\":\"f1.other\"},{\"path\":\"$tree/l\",\"name\":\"a.attr\"}]"
out=""; err=""; rc=0; capture "$BIN" --json lst --values "$tree/f1"
assert_out '[{"name":"f1.attr","text":"one"},{"name":"f1.other","text":"two"}]'
printf '\x00\x01\xfe\xff' | "$BIN" put "$tree/a/x/deep" small.bin
out=""; err=""; rc=0; capture "$BIN" --json dump "$tree/a/x/deep"
[[ "$out" == *'{"name":"small.bin","pb":"·¯żŻ"}'* ]] && pass || fail "json pb value: '$out'"
out=""; err=""; rc=0; capture "$BIN" --json --hex dump "$tree/a/x/deep"
[[ "$out" == *'{"name":"small.bin","hex":"0001feff"}'* ]] && pass || fail "json hex value: '$out'"
"$BIN" del "$tree/a/x/deep" small.bin

current="dangling symlinks are skipped silently when recursing"
ln -s does-not-exist "$tree/dangling"
out=""; err=""; rc=0; capture "$BIN" lst -r "$tree"
assert_rc 0
assert_err_empty
[[ "$out" != *"dangling"* ]] && pass || fail "dangling link should not appear: '$out'"
# Asked for directly it is still an error, because the caller named it.
out=""; err=""; rc=0; capture "$BIN" lst "$tree/dangling"
assert_rc 7
# With --nofollow the link itself is the subject and has no attributes: no warning either.
out=""; err=""; rc=0; capture "$BIN" --nofollow lst -r "$tree"
assert_rc 0
assert_err_empty
# --debug or DEBUG=<non-empty, not 0> shows the skips as debug notes; exit code unaffected.
out=""; err=""; rc=0; capture "$BIN" --debug lst -r "$tree"
assert_rc 0
assert_err_has "debug"
assert_err_has "$tree/dangling"
out=""; err=""; rc=0; DEBUG=1 capture "$BIN" lst -r "$tree"
assert_rc 0
assert_err_has "$tree/dangling"
out=""; err=""; rc=0; DEBUG=0 capture "$BIN" lst -r "$tree"
assert_err_empty
out=""; err=""; rc=0; DEBUG= capture "$BIN" lst -r "$tree"
assert_err_empty
out=""; err=""; rc=0; capture "$BIN" --json --debug lst -r "$tree"
[[ "$err" =~ ^\{\"debug\": ]] && pass || fail "json debug note: '$err'"
rm -f "$tree/dangling"

current="max width truncates displayed values with an ellipsis and byte count"
ESC=$'\e'
wf="$(new_file wide)"
printf 'abcdefghij' | "$BIN" put "$wf" long
printf 'one' | "$BIN" put "$wf" short
printf 'ünï' | "$BIN" put "$wf" uni
printf '\x00\x01\xfe\xff' | "$BIN" put "$wf" bin
for form in "-w 4" "-w=4" "--max-width 4" "--max-width=4"; do
	# shellcheck disable=SC2086
	out=""; err=""; rc=0; capture "$BIN" dump $form "$wf"
	assert_rc 0
	assert_out "bin	pb	·¯żŻ
long	text	abcd…(10 bytes)
short	text	one
uni	text	ünï"
done
# Cuts fall on code points, never inside a UTF-8 sequence.
out=""; err=""; rc=0; capture "$BIN" dump -w 2 "$wf"
assert_out "bin	pb	·¯…(4 bytes)
long	text	ab…(10 bytes)
short	text	on…(3 bytes)
uni	text	ün…(5 bytes)"
out=""; err=""; rc=0; capture "$BIN" --hex dump -w 4 "$wf"
[[ "$out" == *"bin	hex	0001…(4 bytes)"* ]] && pass || fail "hex truncation: '$out'"
out=""; err=""; rc=0; capture "$BIN" dump -w 8 "$tree/a/x/deep"
assert_out "deep.attr	pb	·¯«»ϟ¿¡ª…(256 bytes)"
# 0 means unlimited; JSON is never truncated; garbage is a usage error.
out=""; err=""; rc=0; capture "$BIN" dump -w 4 -w 0 "$wf"
[[ "$out" == *"long	text	abcdefghij"* ]] && pass || fail "-w 0 should lift the limit: '$out'"
out=""; err=""; rc=0; capture "$BIN" --json dump -w 4 "$wf"
[[ "$out" == *'{"name":"long","text":"abcdefghij"}'* ]] && pass || fail "JSON must not be truncated: '$out'"
out=""; err=""; rc=0; capture "$BIN" dump -w nope "$wf"
assert_rc 2
out=""; err=""; rc=0; capture "$BIN" --color dump -w 4 "$wf"
[[ "$out" == *"${ESC}[38;5;208mlong${ESC}[0m	text	${ESC}[38;5;117mabcd${ESC}[0m…(10 bytes)"* ]] && pass || fail "colored truncation: '$out'"

current="ansi color: names bright orange, values light blue, only on a terminal"
ESC=$'\e'
orange="${ESC}[38;5;208m"; blue="${ESC}[38;5;117m"; reset="${ESC}[0m"
# Captured output is not a terminal: no ANSI by default.
out=""; err=""; rc=0; capture "$BIN" dump "$tree/f1"
[[ "$out" != *"$ESC"* ]] && pass || fail "no ANSI when stdout is not a tty"
# --color forces it, exact bytes.
out=""; err=""; rc=0; capture "$BIN" --color dump "$tree/f1"
assert_out "${orange}f1.attr${reset}	text	${blue}one${reset}
${orange}f1.other${reset}	text	${blue}two${reset}"
out=""; err=""; rc=0; capture "$BIN" --color lst -d 0 "$tree"
assert_out "$tree	${orange}root.attr${reset}"
out=""; err=""; rc=0; capture "$BIN" --color lst "$tree/f1"
assert_out "${orange}f1.attr${reset}
${orange}f1.other${reset}"
# Later switches win; JSON is never colored; NO_COLOR is honoured.
for off in --no-color --no-ansi --simple; do
	out=""; err=""; rc=0; capture "$BIN" --color "$off" dump "$tree/f1"
	[[ "$out" != *"$ESC"* ]] && pass || fail "$off should disable color"
done
out=""; err=""; rc=0; capture "$BIN" --color --json dump "$tree/f1"
[[ "$out" != *"$ESC"* ]] && pass || fail "JSON must never carry ANSI"
if [[ "$(os_name)" == "Linux" ]] && command -v script >/dev/null 2>&1; then
	out="$(script -qec "$BIN dump '$tree/f1'" /dev/null | tr -d '\r')"
	[[ "$out" == *"$orange"* && "$out" == *"$blue"* ]] && pass || fail "expected ANSI on a pty: '$out'"
	out="$(NO_COLOR=1 script -qec "$BIN dump '$tree/f1'" /dev/null | tr -d '\r')"
	[[ "$out" != *"$ESC"* ]] && pass || fail "NO_COLOR should disable ANSI on a pty"
fi

current="syscall budget: one listxattr per node, one getxattr per small value"
if [[ "$(os_name)" == "Linux" ]] && command -v strace >/dev/null 2>&1; then
	sc="$tmpdir/strace.txt"
	strace -f -e trace=listxattr,getxattr -c -o "$sc" "$BIN" lst -r "$tree" >/dev/null 2>&1
	n_list="$(awk '$NF=="listxattr"{print $4}' "$sc")"
	[[ "${n_list:-0}" -eq 9 ]] && pass || fail "expected 9 listxattr for 9 visited nodes, got '${n_list:-0}'"
	strace -f -e trace=listxattr,getxattr -c -o "$sc" "$BIN" dump -r "$tree" >/dev/null 2>&1
	n_get="$(awk '$NF=="getxattr"{print $4}' "$sc")"
	[[ "${n_get:-0}" -eq 7 ]] && pass || fail "expected 7 getxattr for 7 small values, got '${n_get:-0}'"
fi

current="unreadable subdirectory is a warning, not a stop"
if [[ "$(id -u)" -ne 0 ]]; then
	chmod 000 "$tree/b"
	out=""; err=""; rc=0; capture "$BIN" lst -r "$tree"
	chmod 755 "$tree/b"
	assert_rc 1
	assert_err_has "warning"
	assert_err_has "$tree/b"
	[[ "$out" == *"deep.attr"* ]] && pass || fail "walk should continue past an unreadable directory"
fi

current="not found path"
out=""; err=""; rc=0; capture "$BIN" put "$missing_path" k <<<"v"
assert_rc 7
assert_err_has "XS_NOT_FOUND"
out=""; err=""; rc=0; capture "$BIN" lst "$missing_path"
assert_rc 7

current="limit"
f="$(new_file f6)"
out=""; err=""; rc=0; capture "$BIN" --limit 4 put "$f" k <<<"1234"
assert_rc 6
assert_err_has "XS_TOO_LARGE"
out=""; err=""; rc=0; capture "$BIN" --limit 4 --limit 100 put "$f" k <<<"1234"
assert_rc 0
out=""; err=""; rc=0; capture "$BIN" --limit 4 get "$f" k
assert_rc 6
# Default bound is 64 KiB on every OS (the smallest OS ceiling, Linux's).
head -c 65537 /dev/zero >"$tmpdir/big"
out=""; err=""; rc=0; capture "$BIN" put "$f" big <"$tmpdir/big"
assert_rc 6
assert_err_has "XS_TOO_LARGE"
out=""; err=""; rc=0; capture "$BIN" --help
[[ "$out" == *"65536"* ]] && pass || fail "help should state the 65536 default limit"
if [[ "$(os_name)" == "Linux" ]]; then
	out=""; err=""; rc=0; capture "$BIN" limits "$f"
	assert_out "65536"
fi

current="limits"
out=""; err=""; rc=0; capture "$BIN" limits "$f"
assert_rc 0
[[ "$out" =~ ^-?[0-9]+$ ]] && pass || fail "limits not an integer: '$out'"
out=""; err=""; rc=0; capture "$BIN" limits
assert_rc 0

current="raw names"
f="$(new_file f7)"
"$BIN" put "$f" rawtest <<<"v" || fail "put"
out=""; err=""; rc=0; capture "$BIN" --raw len "$f" "$(native_name rawtest)"
assert_out "2"
out=""; err=""; rc=0; capture "$BIN" --raw lst "$f"
[[ "$out" == *"$(native_name rawtest)"* ]] && pass || fail "raw lst missing native name: '$out'"
out=""; err=""; rc=0; capture "$BIN" --raw del "$f" "$(native_name rawtest)"
assert_rc 0
out=""; err=""; rc=0; capture "$BIN" len "$f" rawtest
assert_out "-1"

current="paths with spaces"
mkdir -p "$tmpdir/dir with spaces"
f="$tmpdir/dir with spaces/file name.txt"
: >"$f"
out=""; err=""; rc=0; capture "$BIN" put "$f" k <<<"spaced"
assert_rc 0
out=""; err=""; rc=0; capture "$BIN" get "$f" k
assert_out "spaced"
out=""; err=""; rc=0; capture "$BIN" put "$tmpdir/dir with spaces" k <<<"on-dir"
assert_rc 0
out=""; err=""; rc=0; capture "$BIN" get "$tmpdir/dir with spaces" k
assert_out "on-dir"

current="option order and --"
f="$(new_file f8)"
out=""; err=""; rc=0; capture "$BIN" put --limit 100 "$f" k <<<"v"
assert_rc 0
out=""; err=""; rc=0; capture "$BIN" len "$f" --json k
assert_out '{"len":2}'
out=""; err=""; rc=0; capture "$BIN" put -- "$f" k <<<"w"
assert_rc 0
out=""; err=""; rc=0; capture "$BIN" get -- "$f" k
assert_out "w"

current="symlink policy"
f="$(new_file target)"
ln -s "$f" "$tmpdir/link"
out=""; err=""; rc=0; capture "$BIN" put "$tmpdir/link" k <<<"via-link"
assert_rc 0
out=""; err=""; rc=0; capture "$BIN" len "$f" k
assert_out "9"
out=""; err=""; rc=0; capture "$BIN" --nofollow put "$tmpdir/link" k <<<"on-link"
case "$(os_name)" in
	Linux)
		assert_rc 5
		assert_err_has "XS_PERMISSION"
		;;
	*)
		assert_rc 0
		out=""; err=""; rc=0; capture "$BIN" --nofollow len "$tmpdir/link" k
		assert_out "8"
		;;
esac

echo "CLI tests: $passes passed, $failures failed"
exit "$failures"
