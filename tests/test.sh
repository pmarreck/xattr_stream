#!/usr/bin/env bash
set -euo pipefail

source "$HOME/dotfiles/bin/src/capture.bash"
: "${PRINTABLE_BINARY_MUTE_STATS:=}"

BIN="${1:-}"
if [[ -z "${BIN:-}" || ! -x "$BIN" ]]; then
	echo "Error: test requires compiled binary path as argv[1]" >&2
	exit 2
fi

fail() {
	echo "TEST FAIL: $*" >&2
	return 1
}

tmpdir=""
cleanup() {
	[[ -n "${tmpdir:-}" ]] && rm -rf "$tmpdir"
}
trap cleanup EXIT

setup_tmp() {
	local base="${TMPDIR:-/tmp}"
	case "$base" in
		*/) ;;
		*) base="$base/" ;;
	esac
	tmpdir="$(mktemp -d "${base}xattr_stream.XXXXXX")"
}

os_name() {
	uname -s
}

test_xattr_name() {
	case "$(os_name)" in
		Linux) printf '%s\n' 'user.xattr_stream.test' ;;
		Darwin) printf '%s\n' 'com.openai.xattr_stream.test' ;;
		*) printf '%s\n' 'user.xattr_stream.test' ;;
	esac
}

skip_if_xattr_unsupported() {
	local path="$1"
	local xname="$2"
	local out err rc
	out=""; err=""; rc=0
	capture "$BIN" len "$path" "$xname"
	if [[ "$rc" -eq 3 || ( "$rc" -ne 0 && "$err" == *"ENOTSUP"* ) ]]; then
		echo "SKIP: filesystem does not support xattrs"
		exit 0
	fi
}

test_help() {
	local out
	out=$("$BIN" --help)
	if [[ "$out" != *"Usage:"* ]]; then
		fail "help missing Usage:"
		return 1
	fi
	if [[ "$out" != *"put"* || "$out" != *"get"* || "$out" != *"len"* || "$out" != *"del"* || "$out" != *"lst"* || "$out" != *"limits"* ]]; then
		fail "help missing commands list"
		return 1
	fi
}

test_version() {
	local out err rc
	out=""; err=""; rc=0
	capture "$BIN" --version
	[[ "$rc" -eq 0 ]] || fail "version: rc=$rc stderr=$err"
	[[ "$out" == xattr_stream* ]] || fail "version: unexpected stdout: $out"
}

test_limits() {
	local out err rc
	out=""; err=""; rc=0
	capture "$BIN" limits
	[[ "$rc" -eq 0 ]] || fail "limits: rc=$rc stderr=$err"
	out="${out%$'\n'}"
	[[ "$out" =~ ^-?[0-9]+$ ]] || fail "limits: expected integer bytes got: $out"
}

test_len_missing() {
	setup_tmp
	local f="$tmpdir/file"
	: >"$f"

	local xname
	xname="$(test_xattr_name)"

	skip_if_xattr_unsupported "$f" "$xname"

	local out err rc
	out=""; err=""; rc=0
	capture "$BIN" len "$f" "$xname"
	[[ "$rc" -eq 0 ]] || fail "len missing: expected rc=0 got $rc (stderr=$err)"
	[[ "$out" == "-1"* ]] || fail "len missing: expected -1 got: $out"
}

test_put_get_roundtrip_binary() {
	setup_tmp
	local f="$tmpdir/file"
	: >"$f"

	local xname
	xname="$(test_xattr_name)"

	skip_if_xattr_unsupported "$f" "$xname"

	local expected="$tmpdir/expected.bin"
	local got="$tmpdir/got.bin"
	printf '%b' 'a\0b\n\377' >"$expected"

	local out err rc
	out=""; err=""; rc=0
	capture "$BIN" put "$f" "$xname" <"$expected"
	[[ "$rc" -eq 0 ]] || fail "put: rc=$rc stderr=$err"

	out=""; err=""; rc=0
	capture "$BIN" len "$f" "$xname"
	[[ "$rc" -eq 0 ]] || fail "len after put: rc=$rc stderr=$err"
	[[ "$out" == "5"* ]] || fail "len after put: expected 5 got: $out"

	out=""; err=""; rc=0
	BIN_PATH="$BIN" FILE_PATH="$f" XNAME="$xname" OUTFILE="$got" \
		capture bash -c '"$BIN_PATH" get "$FILE_PATH" "$XNAME" >"$OUTFILE"'
	[[ "$rc" -eq 0 ]] || fail "get: rc=$rc stderr=$err"
	cmp -s "$expected" "$got" || fail "get round-trip mismatch"
}

test_del_and_lst() {
	setup_tmp
	local f="$tmpdir/file"
	: >"$f"

	local xname
	xname="$(test_xattr_name)"

	skip_if_xattr_unsupported "$f" "$xname"

	local out err rc
	out=""; err=""; rc=0
	capture "$BIN" put "$f" "$xname" <<<"hello"
	[[ "$rc" -eq 0 ]] || fail "put: rc=$rc stderr=$err"

	out=""; err=""; rc=0
	capture "$BIN" lst "$f"
	[[ "$rc" -eq 0 ]] || fail "lst: rc=$rc stderr=$err"
	printf '%s' "$out" | grep -Fxq "$xname" || fail "lst missing $xname (out=$out)"

	out=""; err=""; rc=0
	capture "$BIN" del "$f" "$xname"
	[[ "$rc" -eq 0 ]] || fail "del: rc=$rc stderr=$err"

	out=""; err=""; rc=0
	capture "$BIN" len "$f" "$xname"
	[[ "$rc" -eq 0 ]] || fail "len after del: expected rc=0 got $rc (stderr=$err)"
	[[ "$out" == "-1"* ]] || fail "len after del: expected -1 got: $out"

	out=""; err=""; rc=0
	capture "$BIN" lst "$f"
	[[ "$rc" -eq 0 ]] || fail "lst after del: rc=$rc stderr=$err"
	if printf '%s' "$out" | grep -Fxq "$xname"; then
		fail "lst after del unexpectedly contains $xname (out=$out)"
	fi
}

test_nofollow_symlink() {
	setup_tmp
	local f="$tmpdir/file"
	local l="$tmpdir/link"
	: >"$f"
	ln -s "$f" "$l"

	local xname
	xname="$(test_xattr_name)"

	skip_if_xattr_unsupported "$f" "$xname"

	local out err rc
	out=""; err=""; rc=0
	capture "$BIN" --nofollow put "$l" "$xname" <<<"hi"
	if [[ "$rc" -eq 3 ]]; then
		echo "SKIP: --nofollow symlink xattrs unsupported"
		return 0
	fi
	if [[ "$rc" -ne 0 && ( "$err" == *"EPERM"* || "$err" == *"Operation not permitted"* ) ]]; then
		echo "SKIP: --nofollow symlink xattrs not permitted"
		return 0
	fi
	[[ "$rc" -eq 0 ]] || fail "nofollow put: rc=$rc stderr=$err"

	out=""; err=""; rc=0
	capture "$BIN" len "$l" "$xname"
	[[ "$rc" -eq 0 ]] || fail "len follow on symlink: rc=$rc stderr=$err"
	[[ "$out" == "-1"* ]] || fail "len follow on symlink: expected -1 got: $out"

	out=""; err=""; rc=0
	capture "$BIN" --nofollow len "$l" "$xname"
	[[ "$rc" -eq 0 ]] || fail "len nofollow on symlink: rc=$rc stderr=$err"
	[[ "$out" == "2"* ]] || fail "len nofollow on symlink: expected 2 got: $out"
}

test_help
test_version
test_limits
test_len_missing
test_put_get_roundtrip_binary
test_del_and_lst
test_nofollow_symlink
echo "TEST SUMMARY: All tests passed"
