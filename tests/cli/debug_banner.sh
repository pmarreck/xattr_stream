#!/usr/bin/env bash
# Checks the debug-build banner of an xattr-stream binary:
#   debug_banner.sh <binary> debug     the banner is on stderr, in yellow, and
#                                      MUTE_DEBUG_STATUS=1 silences it
#   debug_banner.sh <binary> release   no banner, even with the variable unset
# No `set -e`; failures are counted.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/capture.bash
source "$ROOT/tests/lib/capture.bash"
BIN="${1:-}" kind="${2:-}"
banner=$'\e[33mDEBUG BUILD!\e[0m'
failures=0
check() { "$@" || { echo "FAIL [debug banner, $kind]: $BIN" >&2; failures=$((failures + 1)); }; }
out=""; err=""; rc=0
case "$kind" in
	debug)
		capture env -u MUTE_DEBUG_STATUS "$BIN" --version
		check [ "$rc" -eq 0 ]
		check [ "$err" == "$banner" ]
		check test "${out#xattr-stream }" != "$out"
		capture env MUTE_DEBUG_STATUS=1 "$BIN" --version
		check [ -z "$err" ]
		;;
	release)
		capture env -u MUTE_DEBUG_STATUS "$BIN" --version
		check [ "$rc" -eq 0 ]
		check [ -z "$err" ]
		;;
	*) echo "usage: debug_banner.sh <binary> debug|release" >&2; exit 2 ;;
esac
[[ $failures -eq 0 ]] && echo "debug banner ($kind): ok"
[[ $failures -eq 0 ]]
