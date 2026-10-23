//! Logical attribute-name policy: one portable name grammar mapped onto each
//! OS's native rules. Pure computation, no I/O. Port of src/names.zig.
//!
//! Logical mode (default): the caller's name has no OS namespace. Linux stores
//! it under `user.<name>`; macOS and Windows store it verbatim. The mapping is
//! a bijection, so `from_native(to_native(x)) == x`, and native names that are
//! not reachable from the logical layer (other Linux namespaces,
//! `com.apple.*`, NTFS `$` streams, `Zone.Identifier`) are hidden from logical
//! listings.
//!
//! Raw mode: names pass through untouched except for hard OS limits and, on
//! Windows, the three path-injection characters (`:`, `\`, `/`).

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Os {
	Linux,
	Macos,
	Windows,
}

/// Why a name is refused. The order matches `enum xs_name_rejection` in the
/// C header (`XS_NAME_EMPTY` = 1 and so on).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Rejection {
	Empty = 1,
	TooLong = 2,
	ControlChar = 3,
	ForbiddenChar = 4,
	Reserved = 5,
	NotUtf8 = 6,
	EdgeWhitespaceOrDot = 7,
	/// Starts with `user.`: the Linux namespace is applied by the library and
	/// must not be spelled by the caller (it would store user.user.x on Linux).
	LinuxNamespace = 8,
	/// Raw mode only: fails a hard OS limit or a Windows path-injection rule.
	InvalidNative = 9,
}

/// macOS XATTR_MAXNAMELEN (127) is the strictest of the three targets, so it
/// bounds the portable grammar.
pub const MAX_LOGICAL_LEN: usize = 127;
pub const LINUX_USER_PREFIX: &[u8] = b"user.";

/// Characters that are illegal in Windows stream names or would inject a path
/// component; rejected on every OS so a portable name is valid everywhere.
const FORBIDDEN_CHARS: &[u8] = b"/\\:*?\"<>|";
/// Windows path-injection characters, rejected even in raw mode.
const WINDOWS_INJECTION_CHARS: &[u8] = b":\\/";
const RESERVED_PREFIXES_CI: [&[u8]; 2] = [b"com.apple.", b"$"];
const RESERVED_EXACT_CI: [&[u8]; 1] = [b"zone.identifier"];

pub fn max_native_len(os: Os) -> usize {
	match os {
		Os::Linux | Os::Windows => 255,
		Os::Macos => 127,
	}
}

fn starts_with_ignore_case(s: &[u8], prefix: &[u8]) -> bool {
	s.len() >= prefix.len() && s[..prefix.len()].eq_ignore_ascii_case(prefix)
}

pub(crate) fn is_utf8(bytes: &[u8]) -> bool {
	std::str::from_utf8(bytes).is_ok()
}

/// Classify a logical name: `None` when it is acceptable on every supported
/// OS, otherwise the first reason it is not.
pub fn validate_logical(name: &[u8]) -> Option<Rejection> {
	if name.is_empty() {
		return Some(Rejection::Empty);
	}
	if name.len() > MAX_LOGICAL_LEN {
		return Some(Rejection::TooLong);
	}
	for &c in name {
		if c < 0x20 || c == 0x7f {
			return Some(Rejection::ControlChar);
		}
		if FORBIDDEN_CHARS.contains(&c) {
			return Some(Rejection::ForbiddenChar);
		}
	}
	if !is_utf8(name) {
		return Some(Rejection::NotUtf8);
	}
	let last = name[name.len() - 1];
	if name[0] == b' ' || last == b' ' || last == b'.' {
		return Some(Rejection::EdgeWhitespaceOrDot);
	}
	if starts_with_ignore_case(name, LINUX_USER_PREFIX) {
		return Some(Rejection::LinuxNamespace);
	}
	if RESERVED_PREFIXES_CI.iter().any(|p| starts_with_ignore_case(name, p)) {
		return Some(Rejection::Reserved);
	}
	if RESERVED_EXACT_CI.iter().any(|e| name.eq_ignore_ascii_case(e)) {
		return Some(Rejection::Reserved);
	}
	None
}

/// Classify a name under the given mode; raw mode reports only `InvalidNative`.
pub fn classify(os: Os, name: &[u8], raw: bool) -> Option<Rejection> {
	if !raw {
		return validate_logical(name);
	}
	match to_native(os, name, true) {
		Ok(_) => None,
		Err(_) => Some(Rejection::InvalidNative),
	}
}

/// Human-readable reason, suitable for CLI and consumer error messages.
pub fn rejection_message(r: Rejection) -> &'static str {
	match r {
		Rejection::Empty => "name is empty",
		Rejection::TooLong => "name is longer than 127 bytes",
		Rejection::ControlChar => "name contains a control character or NUL",
		Rejection::ForbiddenChar => "name contains one of / \\ : * ? \" < > |",
		Rejection::Reserved => "name is reserved by the OS ($..., com.apple..., Zone.Identifier)",
		Rejection::NotUtf8 => "name is not valid UTF-8",
		Rejection::EdgeWhitespaceOrDot => "name has leading/trailing space or a trailing dot",
		Rejection::LinuxNamespace => "the user. prefix is reserved: on Linux the library applies the user. namespace itself, so pass the name without it (or use raw names)",
		Rejection::InvalidNative => "native name is empty, too long, contains NUL, or contains a path character",
	}
}

/// The name is not acceptable for the requested mode and OS.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct InvalidName;

/// Map a caller-facing name to the native name for `os` (no terminator).
pub fn to_native(os: Os, name: &[u8], raw: bool) -> Result<Vec<u8>, InvalidName> {
	if raw {
		if name.is_empty() || name.len() > max_native_len(os) || name.contains(&0) {
			return Err(InvalidName);
		}
		if os == Os::Windows && (name.iter().any(|c| WINDOWS_INJECTION_CHARS.contains(c)) || !is_utf8(name)) {
			return Err(InvalidName);
		}
		return Ok(name.to_vec());
	}
	if validate_logical(name).is_some() {
		return Err(InvalidName);
	}
	Ok(match os {
		Os::Linux => [LINUX_USER_PREFIX, name].concat(),
		Os::Macos | Os::Windows => name.to_vec(),
	})
}

/// Inverse of `to_native`. `None` for native names the logical layer cannot
/// produce, so listings never show names a caller could not address.
pub fn from_native(os: Os, native: &[u8], raw: bool) -> Option<&[u8]> {
	if raw {
		return Some(native);
	}
	let logical = match os {
		Os::Linux => native.strip_prefix(LINUX_USER_PREFIX)?,
		Os::Macos | Os::Windows => native,
	};
	if validate_logical(logical).is_some() {
		return None;
	}
	Some(logical)
}

#[cfg(test)]
mod tests {
	//! Ported from src/names_test.zig: names are tested as sets.
	use super::*;

	const ALL_OS: [Os; 3] = [Os::Linux, Os::Macos, Os::Windows];

	fn accept_set() -> Vec<Vec<u8>> {
		let mut v: Vec<Vec<u8>> = ["a", "llc.mecha.probe", "user_data", "com.example.app", "x.y.z", "with-dash", "ünïcödé", "security.selinux"]
			.iter()
			.map(|s| s.as_bytes().to_vec())
			.collect();
		v.push(vec![b'a'; MAX_LOGICAL_LEN]);
		v
	}

	#[test]
	fn accept_set_maps_to_the_documented_native_form_on_every_os() {
		for name in accept_set() {
			assert_eq!(validate_logical(&name), None);
			for os in ALL_OS {
				let native = to_native(os, &name, false).unwrap();
				match os {
					Os::Linux => assert_eq!(native, [b"user.".as_slice(), &name].concat()),
					_ => assert_eq!(native, name),
				}
				assert_eq!(from_native(os, &native, false), Some(name.as_slice()));
			}
		}
	}

	#[test]
	fn reject_set_is_rejected_with_the_expected_reason_on_every_os() {
		use Rejection::*;
		let mut cases: Vec<(Vec<u8>, Rejection)> = vec![
			(b"".to_vec(), Empty),
			(b"a\x00b".to_vec(), ControlChar),
			(b"a\nb".to_vec(), ControlChar),
			(b"a\x7fb".to_vec(), ControlChar),
			(b"a/b".to_vec(), ForbiddenChar),
			(b"a\\b".to_vec(), ForbiddenChar),
			(b"a:b".to_vec(), ForbiddenChar),
			(b"a*b".to_vec(), ForbiddenChar),
			(b"a?b".to_vec(), ForbiddenChar),
			(b"a\"b".to_vec(), ForbiddenChar),
			(b"a<b".to_vec(), ForbiddenChar),
			(b"a>b".to_vec(), ForbiddenChar),
			(b"a|b".to_vec(), ForbiddenChar),
			(b"..\\x".to_vec(), ForbiddenChar),
			(b"user.foo".to_vec(), LinuxNamespace),
			(b"User.Foo".to_vec(), LinuxNamespace),
			(b"USER.x".to_vec(), LinuxNamespace),
			(b"$DATA".to_vec(), Reserved),
			(b"$foo".to_vec(), Reserved),
			(b"Zone.Identifier".to_vec(), Reserved),
			(b"zone.identifier".to_vec(), Reserved),
			(b"com.apple.quarantine".to_vec(), Reserved),
			(b"COM.APPLE.FinderInfo".to_vec(), Reserved),
			(b"\xff\xfe".to_vec(), NotUtf8),
			(b"trailing.".to_vec(), EdgeWhitespaceOrDot),
			(b"trailing ".to_vec(), EdgeWhitespaceOrDot),
			(b" leading".to_vec(), EdgeWhitespaceOrDot),
			(b".".to_vec(), EdgeWhitespaceOrDot),
			(b"..".to_vec(), EdgeWhitespaceOrDot),
		];
		cases.push((vec![b'a'; MAX_LOGICAL_LEN + 1], TooLong));
		for (name, why) in cases {
			assert_eq!(validate_logical(&name), Some(why), "{name:?}");
			for os in ALL_OS {
				assert_eq!(to_native(os, &name, false), Err(InvalidName));
			}
		}
	}

	#[test]
	fn from_native_hides_names_not_reachable_from_the_logical_layer() {
		for (os, n) in [
			(Os::Linux, "security.selinux"),
			(Os::Linux, "trusted.x"),
			(Os::Linux, "user."),
			(Os::Linux, "bare"),
			(Os::Macos, "com.apple.quarantine"),
			(Os::Windows, "$I30"),
			(Os::Windows, "Zone.Identifier"),
		] {
			assert_eq!(from_native(os, n.as_bytes(), false), None, "{n}");
		}
	}

	#[test]
	fn raw_mode_passes_native_names_through_with_only_hard_limits() {
		assert_eq!(to_native(Os::Linux, b"security.selinux", true).unwrap(), b"security.selinux");
		assert_eq!(to_native(Os::Linux, b"bare", true).unwrap(), b"bare");
		assert_eq!(to_native(Os::Macos, b"com.apple.quarantine", true).unwrap(), b"com.apple.quarantine");
		assert_eq!(to_native(Os::Windows, b"Zone.Identifier", true).unwrap(), b"Zone.Identifier");
		assert_eq!(from_native(Os::Linux, b"security.selinux", true), Some(b"security.selinux".as_slice()));
		let rejected: Vec<(Os, Vec<u8>)> = vec![
			(Os::Linux, b"".to_vec()),
			(Os::Linux, b"a\x00b".to_vec()),
			(Os::Linux, vec![b'a'; 256]),
			(Os::Macos, vec![b'a'; 128]),
			(Os::Windows, vec![b'a'; 256]),
			(Os::Windows, b"a:b".to_vec()),
			(Os::Windows, b"a\\b".to_vec()),
			(Os::Windows, b"a/b".to_vec()),
		];
		for (os, n) in rejected {
			assert_eq!(to_native(os, &n, true), Err(InvalidName), "{os:?} {n:?}");
		}
	}

	#[test]
	fn longest_logical_name_fits_the_native_limit() {
		let n = to_native(Os::Linux, &[b'a'; MAX_LOGICAL_LEN], false).unwrap();
		assert_eq!(n.len(), 5 + MAX_LOGICAL_LEN);
		assert!(n.len() <= max_native_len(Os::Linux));
	}
}
