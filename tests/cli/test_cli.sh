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
for word in put get len del lst dump limits --nofollow --raw --limit --json --quiet --recurse --depth --depth-first --values --about; do
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
allhex="$(od -An -v -tx1 "$allbytes" | tr -d ' \n')"
out=""; err=""; rc=0; capture "$BIN" lst --values "$tree/a/x/deep"
assert_out "deep.attr	hex	$allhex"
out=""; err=""; rc=0; capture "$BIN" lst --values "$tree/b/z"
assert_out "z.attr	text	"
out=""; err=""; rc=0; capture "$BIN" dump "$tree/f1"
assert_out "f1.attr	text	one
f1.other	text	two"
printf 'multi\nline' | "$BIN" put "$tree/f1" f1.multi
out=""; err=""; rc=0; capture "$BIN" dump "$tree/f1"
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
out=""; err=""; rc=0; capture "$BIN" --json dump "$tree/a/x/deep"
assert_out "[{\"name\":\"deep.attr\",\"hex\":\"$allhex\"}]"

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
