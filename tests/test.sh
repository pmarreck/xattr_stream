#!/usr/bin/env bash
set -euo pipefail

BIN="${1:-}"
if [[ -z "${BIN:-}" || ! -x "$BIN" ]]; then
	echo "Error: test requires compiled binary path as argv[1]" >&2
	exit 2
fi

fail() {
	echo "TEST FAIL: $*" >&2
	return 1
}

test_help() {
	local out
	out=$("$BIN" --help)
	if [[ "$out" != *"Usage:"* ]]; then
		fail "help missing Usage:"
		return 1
	fi
	if [[ "$out" != *"put"* || "$out" != *"get"* || "$out" != *"len"* || "$out" != *"del"* || "$out" != *"lst"* ]]; then
		fail "help missing commands list"
		return 1
	fi
}

test_help
echo "TEST SUMMARY: All tests passed"

