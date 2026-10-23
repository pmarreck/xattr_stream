#!/usr/bin/env bash
# Differential test: the same commands through two xattr-stream builds, a
# reference (the C CLI over the Zig core) and a candidate (the Rust CLI), on
# identical seeded fixtures. Stdout, stderr and exit code must match byte for
# byte, and for commands that write, so must the resulting attributes.
#   usage: differential.sh <reference> <candidate> [seed]
# --about is excluded: it names the implementation. No `set -e`: mismatches
# are counted and reported, and the exit code is 1 if there were any.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REF="${1:-}"
CAND="${2:-}"
SEED="${3:-20261023}"
if [[ ! -x "$REF" || ! -x "$CAND" ]]; then
	echo "usage: differential.sh <reference> <candidate> [seed]" >&2
	exit 2
fi
abs() { printf '%s/%s' "$(cd "$(dirname "$1")" && pwd)" "$(basename "$1")"; }
REF="$(abs "$REF")"
CAND="$(abs "$CAND")"
GEN="$ROOT/tests/cli/differential_gen.lua"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/xattr_stream_diff.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/in" "$tmp/vals"
: >"$tmp/in/empty"
printf 'v' >"$tmp/in/v"
printf 'new value' >"$tmp/in/new"
printf 'abcd' >"$tmp/in/four"
head -c 4000 /dev/zero | tr '\0' 'x' >"$tmp/in/4000"
head -c 70000 /dev/zero | tr '\0' 'y' >"$tmp/in/70000"

# A filesystem without attribute support fails the comparison, unless the run
# declares that case with XS_EXPECT_UNSUPPORTED=1 (the Nix build sandbox).
: >"$tmp/probe"
if ! "$REF" put "$tmp/probe" probe <"$tmp/in/v" >/dev/null 2>&1; then
	"$REF" put "$tmp/probe" probe <"$tmp/in/v" >/dev/null 2>&1
	if [[ $? -eq 3 ]]; then
		if [[ "${XS_EXPECT_UNSUPPORTED:-}" == 1 ]]; then
			echo "differential: declared unsupported; not run ($tmp refuses attributes)"
			exit 0
		fi
		echo "differential: $tmp does not support attributes; set XS_EXPECT_UNSUPPORTED=1 where that is expected" >&2
		exit 1
	fi
	echo "differential: the reference cannot write attributes in $tmp" >&2
	exit 2
fi

cases=0
mismatches=0
shown=0

# Runs the reference in directory $1 and the candidate in $2 with stdin from
# $3 and the remaining arguments, then compares all three outputs.
cmp_run() {
	local a="$1" b="$2" in="$3"
	shift 3
	# Bounded in time and output (20 MB), so a runaway build fails the case
	# instead of filling memory.
	(cd "$a" && ulimit -f 40960 && timeout 20 "$REF" "$@" <"$in" >"$tmp/a.out" 2>"$tmp/a.err"; echo "$?" >"$tmp/a.rc")
	(cd "$b" && ulimit -f 40960 && timeout 20 "$CAND" "$@" <"$in" >"$tmp/b.out" 2>"$tmp/b.err"; echo "$?" >"$tmp/b.rc")
	cases=$((cases + 1))
	if ! cmp -s "$tmp/a.out" "$tmp/b.out" || ! cmp -s "$tmp/a.err" "$tmp/b.err" || ! cmp -s "$tmp/a.rc" "$tmp/b.rc"; then
		mismatch "$(printf '%q ' "$@")<$(basename "$in")"
	fi
}

mismatch() {
	mismatches=$((mismatches + 1))
	shown=$((shown + 1))
	[[ $shown -le 8 ]] || return 0
	printf 'MISMATCH: %s\n' "$1" >&2
	local part
	for part in out err rc; do
		cmp -s "$tmp/a.$part" "$tmp/b.$part" && continue
		printf -- '--- %s (reference vs candidate)\n' "$part" >&2
		diff <(cat -v "$tmp/a.$part") <(cat -v "$tmp/b.$part") | head -8 >&2
	done
}

# Builds the seeded tree in the current directory with the reference CLI and
# records its paths and attribute names. Linux filesystems take non-UTF-8
# file names; APFS refuses them, so they are used only where creatable.
paths=()
attrs=()
build_tree() {
	local nonutf=0
	if touch "$(printf 'probe\xe9')" 2>/dev/null; then
		nonutf=1
		rm -f "$(printf 'probe\xe9')"
	fi
	setup_failed=0
	put() { "$REF" put "$1" "$2" <"$3" >/dev/null 2>&1 || { echo "differential: fixture setup failed: put $*" >&2; setup_failed=1; }; }
	path() { paths+=("$1"); }
	attr() { attrs+=("$1" "$2"); }
	# Values over 4 KiB only where the filesystem takes them (not ext4
	# without ea_inode, where a file's attributes share one 4 KiB block).
	local big=0
	: >probe.big
	head -c 8000 /dev/zero | "$REF" put probe.big probe >/dev/null 2>&1 && big=1
	rm -f probe.big
	luajit "$GEN" tree "$SEED" "$tmp/vals" "$nonutf" "$big" >"$tmp/setup.bash" || return 1
	# shellcheck disable=SC1091 # generated script
	source "$tmp/setup.bash"
	[[ $setup_failed -eq 0 && ${#paths[@]} -gt 0 ]]
}

ro="$tmp/ro"
mkdir -p "$ro"
cd "$ro" || exit 2
build_tree || { echo "differential: could not build the fixture" >&2; exit 2; }
cd "$ROOT" || exit 2
none="$tmp/in/empty"

# --- read-only: every path in every listing format -------------------------
listing_flags=("" "--json" "--utf8" "--hex" "--csv" "--table" "--md" "--utf8 --table" "--utf8 --md" "--cols 0,0" "--cols 3,2" "-w 3" "--utf8 -w=2" "--quiet" "--raw")
for p in "${paths[@]}"; do
	for flags in "${listing_flags[@]}"; do
		# shellcheck disable=SC2086 # flags split on purpose
		cmp_run "$ro" "$ro" "$none" $flags lst "$p"
		# shellcheck disable=SC2086
		cmp_run "$ro" "$ro" "$none" $flags dump "$p"
	done
	cmp_run "$ro" "$ro" "$none" len "$p" missing
	cmp_run "$ro" "$ro" "$none" get "$p" missing
	cmp_run "$ro" "$ro" "$none" --json get "$p" 'a:b'
	cmp_run "$ro" "$ro" "$none" get "$p" user.k
	cmp_run "$ro" "$ro" "$none" --nofollow lst "$p"
done
i=0
while [[ $i -lt ${#attrs[@]} ]]; do
	p="${attrs[$i]}" n="${attrs[$((i + 1))]}"
	cmp_run "$ro" "$ro" "$none" get "$p" "$n"
	cmp_run "$ro" "$ro" "$none" len "$p" "$n"
	cmp_run "$ro" "$ro" "$none" --json len "$p" "$n"
	cmp_run "$ro" "$ro" "$none" --limit 5 get "$p" "$n"
	i=$((i + 2))
done
for root in t . t/link t/dangling; do
	for flags in "${listing_flags[@]}" "--depth-first" "--depth 1" "-d=0" "--debug" "--json --debug" "--color" "--color --table" "--utf8 --csv" "--json --raw" "--cols 10,5,0,4 --utf8"; do
		# shellcheck disable=SC2086
		cmp_run "$ro" "$ro" "$none" $flags dump -r "$root"
		# shellcheck disable=SC2086
		cmp_run "$ro" "$ro" "$none" $flags lst -r "$root"
	done
done

# --- read-only: errors, usage and number parsing ----------------------------
while IFS= read -r spec; do
	eval "set -- $spec"
	cmp_run "$ro" "$ro" "$none" "$@"
done <<'CASES'

--bogus
lst
lst a b c
put x
--limit
'--limit' x lst t
'--limit' ' 5' len t k
'--limit' +5 len t k
'--limit' 18446744073709551616 len t k
'--max-width' -1 lst t
'--max-width=' lst t
'-w' ' 2' dump t
--cols '' lst t
--cols 1,2,3,4,5 lst t
--cols=-1 dump -r t
--cols 1,,2 dump t
'--cols=+2, 3' dump t
--depth=1x lst t
'-d' -1 lst t
--root
--root=
foo
--help
-h
--version
limits
limits t
limits nope
--json limits nope
lst nope
--json lst nope
dump -r nope
--json dump -r nope
get t ''
len t "$(printf 'bad\x1fname')"
--json len t "$(printf 'bad\x1fname')"
--json lst "$(printf 't/ctl\x1fchar')"
--json dump "$(printf 't/ctl\x1fchar')"
--json get t "$(printf 'caf\xe9')"
--raw get t user.k
--raw --json lst -r t
-- lst --json
lst -- --json
/json lst t
'/?'
/h
/r /depth:1 /tsv lst t
/limit:5 get t k
/limit=x lst t
/cols:3,4 dump t
/w: dump t
/bogus lst t
/ lst t
lst /json
lst -- /json
--limit=5 get t k
--limit= lst t
get nope k
--json len nope k
del nope k
CASES

# --- writes: fresh identical copies, then compare outputs and state ---------
build_small() {
	mkdir -p "$1/d" && touch "$1/f1" "$1/f2" "$1/d/f3"
	(cd "$1" && "$REF" put f1 k <"$tmp/in/v" && printf '\000\001\376\377' | "$REF" put f2 bin && "$REF" put d/f3 k <"$tmp/in/new") || exit 2
}
luajit "$GEN" fuzz "$SEED" 400 >"$tmp/in/fuzz.ndjson"
printf '%s\n' '{"path":"f1","xattrs":{"a":"1","b":"two words"}}' '' '   ' '{"path_pb":"d⁄f3","xattrs_pb":{"Ĺǧ":"·"}}' >"$tmp/in/good.ndjson"
cmp_state() {
	(cd "$1" && "$REF" --raw --json dump -r . >"$tmp/a.out" 2>"$tmp/a.err"; echo "$?" >"$tmp/a.rc")
	(cd "$2" && "$REF" --raw --json dump -r . >"$tmp/b.out" 2>"$tmp/b.err"; echo "$?" >"$tmp/b.rc")
	cases=$((cases + 1))
	if ! cmp -s "$tmp/a.out" "$tmp/b.out" || ! cmp -s "$tmp/a.err" "$tmp/b.err"; then
		mismatch "resulting state after: $3"
	fi
}
while IFS='|' read -r stdin spec; do
	[[ -n "$stdin" ]] || continue
	rm -rf "$tmp/A" "$tmp/B"
	build_small "$tmp/A"
	build_small "$tmp/B"
	eval "set -- $spec"
	cmp_run "$tmp/A" "$tmp/B" "$tmp/in/$stdin" "$@"
	cmp_state "$tmp/A" "$tmp/B" "$spec"
done <<'CASES'
v|put f1 k
new|set f1 other
empty|put f1 e
4000|put f1 big
4000|--json put f1 big
4000|--quiet put f1 big
70000|put f1 huge
four|--limit 3 put f1 k
v|--limit 0 put f1 k
empty|--limit 0 put f1 k
v|put f1 a:b
v|--json put f1 user.x
v|put missing k
v|--raw put f1 rawname
v|--nofollow put d k
empty|del f1 k
empty|del f1 nope
empty|del f1 ''
empty|--json del missing k
good.ndjson|load
good.ndjson|load -
good.ndjson|load @stdin
good.ndjson|--root . load
empty|load good-missing.ndjson
empty|--json load good-missing.ndjson
fuzz.ndjson|--root . load
fuzz.ndjson|--json --root . load
fuzz.ndjson|--quiet load -
CASES

printf 'differential: %d cases, %d mismatches (seed %s)\n' "$cases" "$mismatches" "$SEED"
[[ $mismatches -eq 0 ]]
