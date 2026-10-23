#!/usr/bin/env bash
# Forbidden-write canaries for scripts/run-isolated, the boundary ./test puts
# around the build-script tests. Each attempt below targets a disposable
# sentinel tree, never project files.
#   isolation_canary.sh attempt SENTINEL readonly|writable
#     makes every kind of write against SENTINEL and requires each to fail
#     (readonly) or succeed (writable, the unconfined control that proves the
#     attempts can change it)
#   isolation_canary.sh fingerprint SENTINEL
#     prints contents, link targets and modes, to compare before and after
# ./test runs: control (unconfined, writable), then confined (readonly) with
# an unchanged fingerprint, plus scratch, exit-status and separation checks.
set -u

fingerprint() {
	(cd "$1" && find . -print | LC_ALL=C sort | while IFS= read -r f; do
		if [[ -L "$f" ]]; then printf '%s -> %s\n' "$f" "$(readlink "$f")"
		elif [[ -f "$f" ]]; then printf '%s %s %s\n' "$f" "$(ls -l "$f" | cut -c1-10)" "$(cat "$f" 2>/dev/null || echo "(unreadable)")"
		else printf '%s %s\n' "$f" "$(ls -ld "$f" | cut -c1-10)"
		fi
	done)
}

attempt() {
	local s="$1" expect="$2" failures=0 scratch
	scratch="${TEST_WORKSPACE:-${TMPDIR:-/tmp}}"
	# try NAME CMD...: one write attempt, judged against the expectation.
	try() {
		local name="$1"
		shift
		if "$@" 2>/dev/null; then
			[[ "$expect" == writable ]] || { echo "FAIL: write allowed: $name" >&2; failures=$((failures + 1)); }
		else
			[[ "$expect" == readonly ]] || { echo "FAIL: control write refused: $name" >&2; failures=$((failures + 1)); }
		fi
	}
	try "relative write" bash -c 'cd "$1" && echo changed >file' _ "$s"
	try "absolute write" bash -c 'echo changed >"$1/file"' _ "$s"
	try "new file" bash -c ': >"$1/new"' _ "$s"
	try "new directory" mkdir "$s/dir"
	ln -sfn "$s" "$scratch/canary-link" || return 1
	try "write through a scratch symlink" bash -c 'echo changed >"$1/canary-link/file"' _ "$scratch"
	try "write through a published link" bash -c 'echo changed >"$1/command"' _ "$s"
	try "link replacement" ln -sfn elsewhere "$s/command"
	try "rename" mv "$s/other" "$s/other2"
	try "chmod" chmod 000 "$s/file"
	[[ "$failures" -eq 0 ]]
}

case "${1:-}" in
	attempt) attempt "${2:?}" "${3:?}" ;;
	fingerprint) fingerprint "${2:?}" ;;
	*) echo "usage: isolation_canary.sh attempt SENTINEL readonly|writable | fingerprint SENTINEL" >&2; exit 2 ;;
esac
