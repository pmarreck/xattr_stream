# shellcheck shell=bash
# Platform name (PF) of the running environment: <OS>-<ARCH>, with OS linux,
# macos or mswin and ARCH amd64 or arm64. WSL reports linux. Sourced by the
# build and test scripts; prints nothing and returns 1 for an unsupported host.
host_pf() {
	local os arch
	case "$(uname -s)" in
		Linux) os=linux ;;
		Darwin) os=macos ;;
		MINGW*|MSYS*|CYGWIN*) os=mswin ;;
		*) return 1 ;;
	esac
	case "$(uname -m)" in
		x86_64|amd64|AMD64) arch=amd64 ;;
		aarch64|arm64|ARM64) arch=arm64 ;;
		*) return 1 ;;
	esac
	printf '%s-%s' "$os" "$arch"
}
