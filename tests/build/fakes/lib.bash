# shellcheck shell=bash
# Shared by the recording fakes of nix, zig, cargo and uname (tests/build/).
# Each fake appends the command line it was given to $FAKE_LOG, fails without
# output when that line matches the ERE in $FAKE_FAIL, and otherwise lays out
# the product tree the real tool produces. Fake executables print an --about
# line naming the implementation and build kind that produced them.
#   FAKE_PF        platform the fake host reports (set with FAKE_UNAME_S/M)
#   FAKE_OMIT      file name a fake build leaves out of its product
#   FAKE_WRONG_PF  when non-empty, host products report another platform

fake_record() {
	printf '%s\n' "$*" >>"${FAKE_LOG:?}"
	if [[ -n "${FAKE_FAIL:-}" && "$*" =~ $FAKE_FAIL ]]; then
		echo "fake: injected failure: $*" >&2
		exit 1
	fi
}

# fake_exe DIR NAME PF VARIANT LABEL
fake_exe() {
	local dir="$1" name="$2" pf="$3" variant="$4" label="$5" suffix=""
	[[ "$name" == "${FAKE_OMIT:-}" ]] && return 0
	[[ -n "$variant" ]] && suffix=" VARIANT=$variant"
	mkdir -p "$dir"
	printf '#!/bin/sh\necho "xattr-stream 0.2.0: fake %s PF=%s%s"\n' "$label" "$pf" "$suffix" >"$dir/$name"
	chmod +x "$dir/$name"
}

# fake_lib DIR: the library files a product tree carries besides the CLI.
fake_lib() {
	mkdir -p "$1/lib" "$1/include"
	: >"$1/lib/libxattr_stream.a"
	: >"$1/include/xattr_stream.h"
}

fake_host_pf() {
	if [[ -n "${FAKE_WRONG_PF:-}" ]]; then echo "linux-arm64"; else echo "${FAKE_PF:?}"; fi
}

fake_exe_suffix() {
	[[ "$1" == mswin-* ]] && echo ".exe"
	return 0
}
