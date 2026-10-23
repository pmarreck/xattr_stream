#!/usr/bin/env bash
# Line endings and switch spelling of a CLI binary on the platform it runs
# on, without the full suite: CRLF and /name switches exactly when the
# effective platform is mswin (the OS environment variable when it is linux,
# macos or mswin, else the platform the binary was built for; Windows itself
# sets OS=Windows_NT). Used natively on the Windows CI runners, where the
# Bash suite is not ported yet, and by ./test.
set -u

BIN="${1:-}"
if [[ -z "$BIN" || ! -x "$BIN" ]]; then
	echo "usage: conventions_smoke.sh <path/to/cli>" >&2
	exit 2
fi
# Git Bash would rewrite /? into a Windows path before the CLI sees it.
export MSYS_NO_PATHCONV=1

about="$("$BIN" --about)"
compiled="${about##* PF=}"
compiled="${compiled%%-*}"
compiled="${compiled%$'\r'}"
case "${OS:-}" in
	linux|macos|mswin) eff="$OS" ;;
	*) eff="$compiled" ;;
esac

failures=0
check() {
	if [[ "$1" == "$2" ]]; then echo "ok: $3"; else echo "FAIL: $3 (expected '$2', got '$1')" >&2; failures=$((failures + 1)); fi
}

if [[ "$eff" == mswin ]]; then want=0d0a; want_rc=0; else want=0a; want_rc=2; fi
got="$("$BIN" --version | tail -c "$(( ${#want} / 2 ))" | od -An -tx1 | tr -d ' \n')"
check "$got" "$want" "--version line ending on $eff (OS='${OS:-}')"
"$BIN" --version | od -An -tx1 | tr -d ' \n' | grep -q '0d0a' && cr=yes || cr=no
check "$cr" "$([[ "$eff" == mswin ]] && echo yes || echo no)" "CR present exactly on mswin"
"$BIN" '/?' >/dev/null 2>&1
check "$?" "$want_rc" "/? is help exactly on mswin"

exit "$failures"
