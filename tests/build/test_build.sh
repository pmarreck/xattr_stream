#!/usr/bin/env bash
# Behavioral tests of ./build: implementation selection (CANONICAL_IMPL and
# `./build canonize`), build scopes (--all-impls, --all-plats, --all), product
# trees <impl>/<PF>/[<VARIANT>/]<profile> and publication into bin/<PF>/.
# Each case copies the build entrypoint into its own disposable project and
# runs it with recording fakes of nix, zig, cargo and uname first on PATH
# (tests/build/fakes), so no real build runs. ./test runs this confined by
# scripts/run-isolated, which makes everything outside its scratch read-only.
# Usage: test_build.sh PROJECT_ROOT
# No `set -e`: error exits are what many cases assert.
set -u

SRC="$(cd "${1:?usage: test_build.sh PROJECT_ROOT}" && pwd)" || exit 2
FAKES="$SRC/tests/build/fakes"
# shellcheck source=../lib/capture.bash
source "$SRC/tests/lib/capture.bash"

BASE="$(mktemp -d "${TEST_WORKSPACE:-${TMPDIR:-/tmp}}/xattr_stream_build.XXXXXX")" || { echo "setup: mktemp failed" >&2; exit 1; }
[[ -d "$BASE" && "$BASE" == */xattr_stream_build.* ]] || { echo "setup: bad scratch '$BASE'" >&2; exit 1; }
cleanup() { rm -rf -- "$BASE"; }
trap cleanup EXIT

passes=0
failures=0
current=""
pass() { passes=$((passes + 1)); }
fail() { failures=$((failures + 1)); printf 'FAIL [%s]: %s\n' "$current" "$*" >&2; }

ALL_PF="linux-amd64 linux-arm64 macos-amd64 macos-arm64 mswin-amd64 mswin-arm64"
SELECTED="implementation canonized. Rerun ./build to rebuild."

# new_project [HOST_PF]: a fresh disposable project ($P) on a fake host. Paths
# contain spaces on purpose.
cases=0
group=main
new_project() {
	local host="${1:-linux-amd64}"
	cases=$((cases + 1))
	CASE="$BASE/$group/case $cases"
	P="$CASE/project dir"
	mkdir -p "$P/scripts" "$P/rust" "$CASE/store" || { echo "setup failed" >&2; exit 1; }
	cp "$SRC/build" "$P/build" && cp "$SRC/scripts/pf.bash" "$P/scripts/pf.bash" || { echo "setup failed" >&2; exit 1; }
	export FAKE_LOG="$CASE/log" FAKE_STORE="$CASE/store" FAKE_PF="$host"
	: >"$FAKE_LOG"
	case "$host" in
		linux-amd64) FAKE_UNAME_S=Linux FAKE_UNAME_M=x86_64 ;;
		linux-arm64) FAKE_UNAME_S=Linux FAKE_UNAME_M=aarch64 ;;
		macos-arm64) FAKE_UNAME_S=Darwin FAKE_UNAME_M=arm64 ;;
		mswin-amd64) FAKE_UNAME_S=MINGW64_NT-10.0-19045 FAKE_UNAME_M=x86_64 ;;
		unsupported) FAKE_UNAME_S=SunOS FAKE_UNAME_M=sparc ;;
	esac
	export FAKE_UNAME_S FAKE_UNAME_M
	unset FAKE_FAIL FAKE_OMIT FAKE_WRONG_PF CARGO_TARGET_DIR
}
# select_impl CONTENT: CANONICAL_IMPL holds CONTENT (printf %b escapes).
select_impl() { printf '%b' "$1" >"$P/CANONICAL_IMPL"; }

run_build() {
	out="" err="" rc=0
	capture env PATH="$FAKES:$PATH" bash -c 'cd "$1" && shift && exec ./build "$@"' run-build "$P" "$@"
}

assert_rc() { [[ "$rc" -eq "$1" ]] && pass || fail "exit $rc, expected $1; stderr: $err"; }
assert_err_has() { [[ "$err" == *"$1"* ]] && pass || fail "stderr lacks '$1': $err"; }
# The builder commands run, in order, with store paths relative to the store.
log_is() {
	local want got
	want="$(printf '%s\n' "$@")"
	got="$(cat "$FAKE_LOG")"
	[[ "$got" == "$want" ]] && pass || fail "builder log:
$got
expected:
$want"
}
log_empty() { [[ ! -s "$FAKE_LOG" ]] && pass || fail "no builder should run; ran: $(cat "$FAKE_LOG")"; }
# published PF: the --about line of bin/PF/xattr-stream(.exe), or "none".
published() {
	local f="$P/bin/$1/xattr-stream"
	[[ "$1" == mswin-* ]] && f="$f.exe"
	if [[ -e "$f" ]]; then "$f" --about; else echo none; fi
}
assert_published() {
	local got
	got="$(published "$1")"
	[[ "$got" == *"fake $2 PF=$1"* ]] && pass || fail "bin/$1: '$got', expected the '$2' product for $1"
}
bin_entries() { (cd "$P" && find bin -mindepth 1 \( -type f -o -type l \) 2>/dev/null | LC_ALL=C sort); }
assert_bin_entries() {
	local want
	want="$(printf '%s\n' "$@" | LC_ALL=C sort)"
	[[ "$(bin_entries)" == "$want" ]] && pass || fail "bin/ holds:
$(bin_entries)
expected:
$want"
}
link_of() { readlink "$P/bin/$1/xattr-stream"; }
same_file_state() { ls -li "$1" 2>/dev/null; }

# Each section below is one function; they run concurrently (see the end).
section_1() {
	current="canonize records the selection and builds nothing"
	new_project
	run_build canonize zig
	assert_rc 0
	[[ "$out" == "zig $SELECTED" ]] && pass || fail "stdout '$out'"
	[[ -z "$err" ]] && pass || fail "stderr '$err'"
	cmp -s "$P/CANONICAL_IMPL" <(printf 'zig\n') && pass || fail "CANONICAL_IMPL holds '$(cat "$P/CANONICAL_IMPL" 2>/dev/null)'"
	log_empty
	[[ ! -e "$P/bin" ]] && pass || fail "canonize created bin/"

	current="repeating canonize leaves the file as it was"
	before="$(same_file_state "$P/CANONICAL_IMPL")"
	run_build canonize zig
	assert_rc 0
	[[ "$out" == "zig $SELECTED" ]] && pass || fail "stdout '$out'"
	[[ "$(same_file_state "$P/CANONICAL_IMPL")" == "$before" ]] && pass || fail "file was rewritten"
	select_impl 'zig'
	before="$(same_file_state "$P/CANONICAL_IMPL")"
	run_build canonize zig
	assert_rc 0
	[[ "$(same_file_state "$P/CANONICAL_IMPL")" == "$before" ]] && pass || fail "a valid selection without LF was rewritten"

}

section_3() {
	current="canonize switches the selection without touching the published command"
	new_project
	select_impl 'zig\n'
	run_build
	assert_rc 0
	before="$(link_of linux-amd64)"
	: >"$FAKE_LOG"
	run_build canonize rust
	assert_rc 0
	[[ "$out" == "rust $SELECTED" ]] && pass || fail "stdout '$out'"
	cmp -s "$P/CANONICAL_IMPL" <(printf 'rust\n') && pass || fail "CANONICAL_IMPL not rust"
	log_empty
	[[ "$(link_of linux-amd64)" == "$before" ]] && pass || fail "canonize changed bin/linux-amd64/xattr-stream"
	assert_published linux-amd64 "zig default"

}

section_4() {
	current="canonize refuses anything but one declared implementation"
	# Each request is a |-separated argument list after `canonize`; "-" is none.
	for request in "-" "" "python" "ZIG" " zig" "zig " "zi" "zigg" "zig|rust" "zig|--all" "zig|--debug" "--all|zig"; do
		new_project
		select_impl 'rust\n'
		before="$(same_file_state "$P/CANONICAL_IMPL")"
		args=()
		[[ "$request" == "-" ]] || IFS='|' read -r -a args <<<"$request|"
		run_build canonize "${args[@]}"
		[[ "$rc" -eq 2 ]] && pass || fail "canonize '$request': exit $rc"
		[[ "$err" == *"zig rust"* ]] && pass || fail "canonize '$request': error should list the implementations: $err"
		[[ "$(same_file_state "$P/CANONICAL_IMPL")" == "$before" ]] && pass || fail "canonize '$request' changed CANONICAL_IMPL"
		log_empty
	done
	new_project
	run_build canonize python
	[[ ! -e "$P/CANONICAL_IMPL" ]] && pass || fail "a refused canonize created CANONICAL_IMPL"
	run_build --all canonize zig
	assert_rc 2
	log_empty

}

section_5() {
	current="CANONICAL_IMPL contents, classified"
	for content in 'zig' 'zig\n' 'rust' 'rust\n'; do
		new_project
		select_impl "$content"
		run_build
		[[ "$rc" -eq 0 ]] && pass || fail "accepted content '$content': exit $rc: $err"
		case "$content" in
			zig*) want="zig default" ;;
			*) want="rust rust" ;;
		esac
		assert_published linux-amd64 "$want"
	done
	for content in '' '\n' 'zig\n\n' '\nzig' ' zig' 'zig ' 'zig\t' 'zig\r\n' 'ZIG' 'Rust' 'zi' 'zigg' 'zig\nrust\n' 'zig\0' 'zig\0\n' 'python\n' \
		'$(touch PWNED)' '`touch PWNED`' 'zig;touch PWNED' 'zig$(touch PWNED)' '../zig'; do
		new_project
		select_impl "$content"
		run_build
		[[ "$rc" -eq 2 ]] && pass || fail "rejected content '$content': exit $rc"
		[[ "$err" == *CANONICAL_IMPL* && "$err" == *"zig rust"* ]] && pass || fail "content '$content': error should name the file and the implementations: $err"
		log_empty
		[[ ! -e "$P/bin" ]] && pass || fail "content '$content': bin/ was created"
		[[ -z "$(find "$CASE" -name PWNED)" ]] && pass || fail "content '$content' ran a command"
	done
	new_project
	run_build
	assert_rc 2
	assert_err_has "./build canonize"
	log_empty

}

section_6() {
	current="default: canonical implementation, this platform"
	new_project
	select_impl 'zig\n'
	run_build
	assert_rc 0
	log_is "nix build .#default --no-link --print-out-paths" "nix build 1-default -o .nix-out/zig/linux-amd64/musl/ReleaseFast"
	assert_published linux-amd64 "zig default"
	[[ "$(link_of linux-amd64)" == "../../.nix-out/zig/linux-amd64/musl/ReleaseFast/bin/xattr-stream" ]] && pass || fail "relative link: $(link_of linux-amd64)"
	assert_bin_entries bin/linux-amd64/xattr-stream
	[[ "$out" == *"published: bin/linux-amd64/xattr-stream"* ]] && pass || fail "stdout: $out"

	new_project
	select_impl 'rust\n'
	run_build
	assert_rc 0
	log_is "nix build .#rust --no-link --print-out-paths" "nix build 1-rust -o .nix-out/rust/linux-amd64/gnu/release"
	assert_published linux-amd64 "rust rust"
	assert_bin_entries bin/linux-amd64/xattr-stream

}

section_7() {
	current="--all-impls builds the other implementation and publishes only the canonical one"
	new_project
	select_impl 'zig\n'
	run_build --all-impls
	assert_rc 0
	log_is "nix build .#default --no-link --print-out-paths" "nix build 1-default -o .nix-out/zig/linux-amd64/musl/ReleaseFast" \
		"nix build .#rust --no-link --print-out-paths" "nix build 2-rust -o .nix-out/rust/linux-amd64/gnu/release"
	assert_published linux-amd64 "zig default"
	assert_bin_entries bin/linux-amd64/xattr-stream
	[[ -x "$P/.nix-out/rust/linux-amd64/gnu/release/bin/xattr-stream-rs" ]] && pass || fail "rust product missing"
	[[ "$out" == *"built: .nix-out/rust/linux-amd64/gnu/release/bin/xattr-stream-rs (rust, not published)"* ]] && pass || fail "stdout should name the unpublished rust product: $out"
	[[ "$out" != *"(zig, not published)"* ]] && pass || fail "the canonical product is reported as unpublished: $out"

}

section_8() {
	current="--all-plats publishes the canonical implementation for all six platforms"
	new_project
	select_impl 'zig\n'
	run_build --all-plats
	assert_rc 0
	log_is "nix build .#default --no-link --print-out-paths" "nix build 1-default -o .nix-out/zig/linux-amd64/musl/ReleaseFast" \
		"nix build .#cross --no-link --print-out-paths" "nix build 2-cross -o .nix-out/zig/cross"
	assert_published linux-amd64 "zig default"
	for pf in linux-arm64 macos-amd64 macos-arm64 mswin-amd64 mswin-arm64; do assert_published "$pf" "zig cross"; done
	assert_bin_entries bin/linux-amd64/xattr-stream bin/linux-arm64/xattr-stream bin/macos-amd64/xattr-stream \
		bin/macos-arm64/xattr-stream bin/mswin-amd64/xattr-stream.exe bin/mswin-arm64/xattr-stream.exe
	[[ "$(link_of linux-arm64)" == "../../.nix-out/zig/cross/linux-arm64/musl/ReleaseFast/bin/xattr-stream" ]] && pass || fail "linux-arm64 link: $(link_of linux-arm64)"
	[[ "$(link_of macos-arm64)" == "../../.nix-out/zig/cross/macos-arm64/ReleaseFast/bin/xattr-stream" ]] && pass || fail "macos-arm64 link: $(link_of macos-arm64)"

	new_project
	select_impl 'rust'
	run_build --all-plats
	assert_rc 0
	assert_published linux-amd64 "rust rust"
	for pf in linux-arm64 macos-amd64 macos-arm64 mswin-amd64 mswin-arm64; do assert_published "$pf" "rust rust-cross"; done
	[[ "$(readlink "$P/bin/mswin-arm64/xattr-stream.exe")" == "../../.nix-out/rust/cross/mswin-arm64/release/bin/xattr-stream-rs.exe" ]] && pass || fail "mswin-arm64 link"

}

section_9() {
	current="--all builds both implementations for all six platforms"
	new_project
	select_impl 'zig\n'
	run_build --all
	assert_rc 0
	log_is "nix build .#default --no-link --print-out-paths" "nix build 1-default -o .nix-out/zig/linux-amd64/musl/ReleaseFast" \
		"nix build .#cross --no-link --print-out-paths" "nix build 2-cross -o .nix-out/zig/cross" \
		"nix build .#rust --no-link --print-out-paths" "nix build 3-rust -o .nix-out/rust/linux-amd64/gnu/release" \
		"nix build .#rust-cross --no-link --print-out-paths" "nix build 4-rust-cross -o .nix-out/rust/cross"
	for pf in linux-arm64 macos-amd64 macos-arm64 mswin-amd64 mswin-arm64; do assert_published "$pf" "zig cross"; done
	[[ -x "$P/.nix-out/rust/cross/linux-arm64/musl/release/bin/xattr-stream-rs" && -x "$P/.nix-out/rust/cross/macos-amd64/release/bin/xattr-stream-rs" ]] && pass || fail "rust cross products missing"

}

section_10() {
	current="scope spellings: aliases, order and repetition select the same set"
	fingerprint() { cat "$FAKE_LOG"; for e in $(bin_entries); do printf '%s %s\n' "$e" "$("$P/$e" --about)"; done; }
	# Each spelling builds in its own project, concurrently; fp K prints
	# what spelling K ran and published (or why it failed).
	local spellings=("--all" "--all-impls --all-plats" "--all-plats --all-impls" "--all-implementations --all-platforms" "--all --all"
		"--all-impls --all --all-plats" "--all-impls --all-impls --all-plats --all-plats" "--all-platforms --all-impls"
		"--all-impls" "--all-implementations" "--all-plats" "--all-platforms" "--all-plats --all-plats")
	local k spelling
	for k in "${!spellings[@]}"; do
		(
			group="$group-$k"
			new_project
			select_impl 'zig\n'
			# shellcheck disable=SC2086
			run_build ${spellings[$k]}
			if [[ "$rc" -eq 0 ]]; then fingerprint; else echo "./build ${spellings[$k]}: exit $rc: $err"; fi >"$BASE/$group.fp"
		) &
	done
	wait
	cases=$((cases + ${#spellings[@]}))
	fp() { cat "$BASE/$group-$1.fp"; }
	for k in 1 2 3 4 5 6 7; do
		[[ "$(fp "$k")" == "$(fp 0)" ]] && pass || fail "'${spellings[$k]}' differs from --all: $(fp "$k")"
	done
	[[ "$(fp 9)" == "$(fp 8)" ]] && pass || fail "--all-implementations differs from --all-impls"
	[[ "$(fp 11)" == "$(fp 10)" ]] && pass || fail "--all-platforms differs from --all-plats"
	[[ "$(fp 12)" == "$(fp 10)" ]] && pass || fail "repeated --all-plats differs"
	[[ "$(fp 0)" != "$(fp 10)" && "$(fp 10)" != "$(fp 8)" ]] && pass || fail "scopes are not distinct"
	[[ "$(fp 0)" == *"bin/macos-arm64/xattr-stream"* ]] && pass || fail "--all published nothing: $(fp 0)"
}

section_11() {
	current="other hosts: no variant directory outside Linux"
	new_project macos-arm64
	select_impl 'zig\n'
	run_build --all-impls
	assert_rc 0
	log_is "nix build .#default --no-link --print-out-paths" "nix build 1-default -o .nix-out/zig/macos-arm64/ReleaseFast" \
		"nix build .#rust --no-link --print-out-paths" "nix build 2-rust -o .nix-out/rust/macos-arm64/release"
	assert_published macos-arm64 "zig default"
	assert_bin_entries bin/macos-arm64/xattr-stream

	new_project macos-arm64
	select_impl 'zig\n'
	run_build --all-plats
	assert_rc 0
	assert_published macos-arm64 "zig default"
	assert_published linux-amd64 "zig cross"

	new_project linux-arm64
	select_impl 'zig\n'
	run_build
	assert_rc 0
	log_is "nix build .#default --no-link --print-out-paths" "nix build 1-default -o .nix-out/zig/linux-arm64/musl/ReleaseFast"
	assert_published linux-arm64 "zig default"

}

section_12() {
	current="Windows hosts get copies, which need no symlink privileges"
	new_project mswin-amd64
	select_impl 'zig\n'
	run_build --all-plats
	assert_rc 0
	for pf in $ALL_PF; do
		f="$P/bin/$pf/xattr-stream"; [[ "$pf" == mswin-* ]] && f="$f.exe"
		[[ -f "$f" && ! -L "$f" ]] && pass || fail "bin/$pf entry is not a plain file"
	done
	assert_published mswin-amd64 "zig default"
	assert_published linux-amd64 "zig cross"

}

section_13() {
	current="usage errors build nothing"
	new_project
	select_impl 'zig\n'
	for args in "--bogus" "zig" "--all-impl" "--debug --all-plats" "--test --all" "--all --debug"; do
		# shellcheck disable=SC2086
		run_build $args
		[[ "$rc" -eq 2 ]] && pass || fail "./build $args: exit $rc"
		log_empty
	done
	new_project unsupported
	select_impl 'zig\n'
	run_build
	assert_rc 2
	assert_err_has "unsupported"
	log_empty
	new_project
	run_build --help
	assert_rc 0
	for word in canonize --all-impls --all-implementations --all-plats --all-platforms --all --debug --test CANONICAL_IMPL; do
		[[ "$out" == *"$word"* ]] && pass || fail "--help does not mention $word"
	done
	log_empty

}

section_14() {
	current="--debug and --test build through the dev shell into <impl>-out trees"
	new_project
	select_impl 'zig\n'
	run_build --debug
	assert_rc 0
	log_is "nix develop -c zig build -Doptimize=Debug --prefix .build-work/zig-out/linux-amd64/musl/Debug" \
		"zig build -Doptimize=Debug --prefix .build-work/zig-out/linux-amd64/musl/Debug"
	assert_published linux-amd64 "zig direct-Debug"
	[[ "$(link_of linux-amd64)" == "../../zig-out/linux-amd64/musl/Debug/bin/xattr-stream" ]] && pass || fail "link: $(link_of linux-amd64)"
	[[ -f "$P/zig-out/linux-amd64/musl/Debug/lib/libxattr_stream.a" ]] && pass || fail "library missing from the product tree"
	run_build --debug --test
	assert_rc 0
	assert_published linux-amd64 "zig direct-ReleaseSafe"
	run_build --test --debug
	assert_rc 0
	assert_published linux-amd64 "zig direct-Debug"

	new_project
	select_impl 'rust\n'
	export CARGO_TARGET_DIR="$CASE/cargo target"
	run_build --test
	assert_rc 0
	log_is "nix develop -c cargo build --release --manifest-path rust/Cargo.toml" "cargo build --release --manifest-path rust/Cargo.toml"
	assert_published linux-amd64 "rust direct-release"
	[[ "$(link_of linux-amd64)" == "../../rust-out/linux-amd64/gnu/release/bin/xattr-stream-rs" ]] && pass || fail "link: $(link_of linux-amd64)"
	[[ -f "$P/rust-out/linux-amd64/gnu/release/bin/xattr-stream-rs" && ! -L "$P/rust-out/linux-amd64/gnu/release/bin/xattr-stream-rs" ]] && pass || fail "product is not a copy"
	[[ -f "$P/rust-out/linux-amd64/gnu/release/lib/libxattr_stream.a" ]] && pass || fail "library missing from the product tree"

	new_project
	select_impl 'rust\n'
	run_build --debug
	assert_rc 0
	assert_published linux-amd64 "rust direct-debug"
	[[ -x "$P/rust/target/debug/xattr-stream-rs" ]] && pass || fail "cargo's default target directory unused"

	new_project macos-arm64
	select_impl 'zig\n'
	run_build --debug --all-impls
	assert_rc 0
	assert_published macos-arm64 "zig direct-Debug"
	[[ -x "$P/rust-out/macos-arm64/debug/bin/xattr-stream-rs" ]] && pass || fail "rust debug product missing"
	assert_bin_entries bin/macos-arm64/xattr-stream

}

section_15() {
	current="a failed build keeps the previous publication"
	new_project
	select_impl 'zig\n'
	run_build
	before="$(link_of linux-amd64)"
	run_build canonize rust
	FAKE_FAIL='^nix build \.#rust' run_build
	assert_rc 1
	[[ "$(link_of linux-amd64)" == "$before" ]] && pass || fail "link changed after a failed build"
	assert_published linux-amd64 "zig default"

}

section_16() {
	current="a product without its CLI is not published or linked"
	new_project
	select_impl 'zig\n'
	run_build
	first="$(readlink "$P/.nix-out/zig/linux-amd64/musl/ReleaseFast")"
	FAKE_OMIT=xattr-stream run_build
	assert_rc 1
	assert_err_has "missing"
	[[ "$(readlink "$P/.nix-out/zig/linux-amd64/musl/ReleaseFast")" == "$first" ]] && pass || fail "the output link moved to the incomplete product"
	assert_published linux-amd64 "zig default"

}

section_17() {
	current="a host product reporting another platform is not published"
	new_project
	select_impl 'zig\n'
	FAKE_WRONG_PF=1 run_build
	assert_rc 1
	assert_err_has "PF=linux-amd64 VARIANT=musl"
	[[ ! -e "$P/bin/linux-amd64/xattr-stream" ]] && pass || fail "published anyway"
	[[ ! -e "$P/.nix-out/zig/linux-amd64/musl/ReleaseFast" ]] && pass || fail "linked anyway"

	new_project
	select_impl 'zig\n'
	run_build --debug
	FAKE_WRONG_PF=1 run_build --debug
	assert_rc 1
	assert_published linux-amd64 "zig direct-Debug"
	[[ "$("$P/zig-out/linux-amd64/musl/Debug/bin/xattr-stream" --about)" == *"PF=linux-amd64 VARIANT=musl" ]] && pass || fail "the product tree took the rejected build"

}

section_18() {
	current="a failed non-canonical or cross build still publishes what succeeded"
	new_project
	select_impl 'zig\n'
	FAKE_FAIL='^nix build \.#rust' run_build --all-impls
	assert_rc 1
	assert_published linux-amd64 "zig default"
	new_project
	select_impl 'zig\n'
	FAKE_FAIL='^nix build \.#cross' run_build --all-plats
	assert_rc 1
	assert_published linux-amd64 "zig default"
	assert_bin_entries bin/linux-amd64/xattr-stream

}

section_19() {
	current="unrelated bin/ entries are left alone"
	new_project
	select_impl 'zig\n'
	mkdir -p "$P/bin/linux-amd64" && printf 'mine\n' >"$P/bin/linux-amd64/other-tool" && printf 'portable\n' >"$P/bin/script"
	run_build --all-plats
	assert_rc 0
	[[ "$(cat "$P/bin/linux-amd64/other-tool")" == mine && "$(cat "$P/bin/script")" == portable ]] && pass || fail "unrelated entries changed"

}

sections=$(declare -F | sed -n "s/^declare -f \(section_[0-9]*\)$/\1/p")
for s in $sections; do
	(
		passes=0 failures=0 cases=0 group="$s"
		"$s"
		echo "$passes $failures $cases" >"$BASE/$s.counts"
	) &
done
wait
total_pass=0 total_fail=0 total_cases=0
for s in $sections; do
	if [[ -f "$BASE/$s.counts" ]]; then
		read -r p f c <"$BASE/$s.counts"
	else
		p=0 f=1 c=0
		echo "FAIL [$s]: section did not finish" >&2
	fi
	total_pass=$((total_pass + p)) total_fail=$((total_fail + f)) total_cases=$((total_cases + c))
done
printf 'build script tests: %d passed, %d failed (%d disposable projects, %d sections in parallel)\n' "$total_pass" "$total_fail" "$total_cases" "$(wc -w <<<"$sections")"
[[ "$total_fail" -eq 0 ]]
