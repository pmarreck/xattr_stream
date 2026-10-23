//! xattr_stream, Rust implementation: binary-safe per-file byte attributes
//! with one portable name grammar and one error taxonomy across Linux
//! (user.* xattrs), macOS (xattrs) and Windows (NTFS alternate data streams).
//! A port of the Zig library in ../src, kept behavior-identical: the Bash CLI
//! suite and a differential test against the Zig/C CLI check that.
//!
//! Hexagonal layout: this file is the port. `names` is pure policy; the OS
//! adapter in `os` is chosen at compile time behind the `Adapter` trait, so
//! the size-query/read race handling is testable with a fake adapter.
//! `ffi` exports the same C ABI as the Zig library (include/xattr_stream.h).
//!
//! Paths are encoded bytes: raw bytes on POSIX, WTF-8 on Windows (what
//! `OsStr::as_encoded_bytes` returns). Names are bytes in the logical grammar,
//! or native bytes in raw mode.
use std::cell::Cell;
use std::ffi::CStr;

pub mod dump;
pub mod ffi;
pub mod names;
pub(crate) mod os;
pub mod pb;
mod pb_map;
pub mod walk;

pub const VERSION: &str = env!("CARGO_PKG_VERSION");

/// The OS this build targets, for name mapping.
pub const OS: names::Os = os::OS;

/// Platform name (PF), `<OS>-<ARCH>`: OS linux, macos or mswin; ARCH amd64 or
/// arm64.
pub const PLATFORM: &str = os::PLATFORM;

/// The stable error taxonomy. `Unsupported` means the filesystem or OS cannot
/// hold attributes at all; it is never evidence that a value was tampered with.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Error {
	/// The attribute does not exist on an existing path.
	Missing,
	/// The filesystem or OS does not support attributes.
	Unsupported,
	/// The filesystem is mounted read-only.
	ReadOnly,
	/// EACCES/EPERM/ACCESS_DENIED, including kernel policy refusals.
	Permission,
	/// Value exceeds the OS, filesystem, or caller `max_value_len` bound.
	TooLarge,
	/// The path itself does not exist.
	NotFound,
	/// The name failed the logical-name policy or an OS name limit.
	InvalidName,
	/// The path is empty, too long, or contains NUL.
	InvalidPath,
	/// The value kept changing between size query and read; retries exhausted.
	Changed,
	/// Caller buffer smaller than the current value (`get_into`).
	BufferTooSmall,
	OutOfMemory,
	/// Any other OS error; see `last_os_error`.
	Io,
}

/// C ABI status codes; the order is frozen and mirrored in include/xattr_stream.h.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Status {
	Ok = 0,
	Missing = 1,
	Unsupported = 2,
	ReadOnly = 3,
	Permission = 4,
	TooLarge = 5,
	NotFound = 6,
	InvalidName = 7,
	InvalidPath = 8,
	Changed = 9,
	BufferTooSmall = 10,
	OutOfMemory = 11,
	Io = 12,
	/// FFI-only: NULL pointer with nonzero length, or NULL out-parameter.
	InvalidArgument = 13,
}

impl Status {
	pub fn of(err: Option<Error>) -> Status {
		match err {
			None => Status::Ok,
			Some(Error::Missing) => Status::Missing,
			Some(Error::Unsupported) => Status::Unsupported,
			Some(Error::ReadOnly) => Status::ReadOnly,
			Some(Error::Permission) => Status::Permission,
			Some(Error::TooLarge) => Status::TooLarge,
			Some(Error::NotFound) => Status::NotFound,
			Some(Error::InvalidName) => Status::InvalidName,
			Some(Error::InvalidPath) => Status::InvalidPath,
			Some(Error::Changed) => Status::Changed,
			Some(Error::BufferTooSmall) => Status::BufferTooSmall,
			Some(Error::OutOfMemory) => Status::OutOfMemory,
			Some(Error::Io) => Status::Io,
		}
	}

	pub fn code(self) -> i32 {
		self as i32
	}
}

/// `XS_*` name of a status code, `XS_UNKNOWN` for anything else.
pub fn status_name(code: i32) -> &'static str {
	const NAMES: [&str; 14] = [
		"XS_OK",
		"XS_MISSING",
		"XS_UNSUPPORTED",
		"XS_READ_ONLY",
		"XS_PERMISSION",
		"XS_TOO_LARGE",
		"XS_NOT_FOUND",
		"XS_INVALID_NAME",
		"XS_INVALID_PATH",
		"XS_CHANGED",
		"XS_BUFFER_TOO_SMALL",
		"XS_OUT_OF_MEMORY",
		"XS_IO",
		"XS_INVALID_ARGUMENT",
	];
	usize::try_from(code).ok().and_then(|i| NAMES.get(i)).copied().unwrap_or("XS_UNKNOWN")
}

/// Default bound on any single value the library will read or write: the
/// smallest OS ceiling across targets, Linux's XATTR_SIZE_MAX (64 KiB), so a
/// value accepted on one platform is accepted on all of them.
pub const DEFAULT_MAX_VALUE_LEN: usize = 64 << 10;
/// Largest value that fits on ext4 without ea_inode next to the longest valid
/// name, as a file's only attribute (see include/xattr_stream.h). Advisory.
pub const PORTABLE_VALUE_LEN: usize = 4096 - 32 - 4 - 16 - 128;
/// Bounded retries when a value changes between size query and read.
pub const MAX_GET_ATTEMPTS: usize = 4;
/// First attempt at any read or listing uses a buffer of this size, so values
/// and name lists that fit cost one syscall instead of a size query plus a read.
pub const OPTIMISTIC_READ_LEN: usize = 4096;

#[derive(Clone, Copy, Debug)]
pub struct Options {
	/// Operate on the symlink target (true) or the link itself (false).
	pub follow_symlinks: bool,
	/// Pass native names through instead of the portable logical grammar.
	pub raw_names: bool,
	/// Reject values larger than this on set, and before allocating on get.
	pub max_value_len: usize,
}

impl Default for Options {
	fn default() -> Self {
		Options { follow_symlinks: true, raw_names: false, max_value_len: DEFAULT_MAX_VALUE_LEN }
	}
}

thread_local! {
	static LAST_OS_ERROR: Cell<i32> = const { Cell::new(0) };
}

/// Raw OS error (errno or Win32 code) behind the most recent failure on this
/// thread. Only attribute calls set it; directory walking does not.
pub fn last_os_error() -> i32 {
	LAST_OS_ERROR.with(|c| c.get())
}

pub(crate) fn set_last_os_error(code: i32) {
	LAST_OS_ERROR.with(|c| c.set(code));
}

/// The five attribute primitives an OS provides. Arguments are validated,
/// NUL-terminated native spellings.
pub trait Adapter {
	fn size(&self, path: &CStr, name: &CStr, nofollow: bool) -> Result<usize, Error>;
	fn read(&self, path: &CStr, name: &CStr, nofollow: bool, buf: &mut [u8]) -> Result<usize, Error>;
	fn write(&self, path: &CStr, name: &CStr, nofollow: bool, value: &[u8]) -> Result<(), Error>;
	fn remove(&self, path: &CStr, name: &CStr, nofollow: bool) -> Result<(), Error>;
	/// Native names packed NUL-terminated, as listxattr returns them.
	fn list_raw(&self, path: &CStr, nofollow: bool) -> Result<Vec<u8>, Error>;
	fn limits(&self, path: &CStr) -> i64;
}

// Windows paths are WTF-8 here and can reach 32767 UTF-16 units; POSIX paths
// are bounded by PATH_MAX (4096 on Linux, 1024 on macOS).
const PATH_BUF_LEN: usize = if cfg!(windows) { 32767 * 3 + 1 } else { 4096 + 1 };

fn path_z(path: &[u8]) -> Result<std::ffi::CString, Error> {
	if path.is_empty() || path.len() >= PATH_BUF_LEN {
		return Err(Error::InvalidPath);
	}
	std::ffi::CString::new(path).map_err(|_| Error::InvalidPath)
}

/// Native (OS-level) spelling of a name under `opts`.
pub fn native_name(name: &[u8], opts: &Options) -> Result<Vec<u8>, Error> {
	names::to_native(OS, name, opts.raw_names).map_err(|_| Error::InvalidName)
}

fn name_z(name: &[u8], opts: &Options) -> Result<std::ffi::CString, Error> {
	// Native names never contain NUL (to_native refuses it).
	std::ffi::CString::new(native_name(name, opts)?).map_err(|_| Error::InvalidName)
}

/// Create or atomically replace (POSIX) the attribute.
pub fn set(path: &[u8], name: &[u8], value: &[u8], opts: &Options) -> Result<(), Error> {
	set_with(&os::Native, path, name, value, opts)
}

fn set_with(a: &impl Adapter, path: &[u8], name: &[u8], value: &[u8], opts: &Options) -> Result<(), Error> {
	let n = name_z(name, opts)?;
	let p = path_z(path)?;
	if value.len() > opts.max_value_len {
		return Err(Error::TooLarge);
	}
	a.write(&p, &n, !opts.follow_symlinks, value)
}

/// Current value length in bytes; `Error::Missing` when absent.
pub fn size(path: &[u8], name: &[u8], opts: &Options) -> Result<usize, Error> {
	let n = name_z(name, opts)?;
	let p = path_z(path)?;
	os::Native.size(&p, &n, !opts.follow_symlinks)
}

/// Read into a caller buffer without allocating. Returns the byte count;
/// `Error::BufferTooSmall` when the value does not fit.
pub fn get_into(path: &[u8], name: &[u8], buf: &mut [u8], opts: &Options) -> Result<usize, Error> {
	let n = name_z(name, opts)?;
	let p = path_z(path)?;
	let nofollow = !opts.follow_symlinks;
	if buf.is_empty() {
		// A zero-length read is a size query on POSIX, so answer it explicitly.
		let s = os::Native.size(&p, &n, nofollow)?;
		return if s == 0 { Ok(0) } else { Err(Error::BufferTooSmall) };
	}
	os::Native.read(&p, &n, nofollow, buf)
}

/// Read the whole value.
pub fn get(path: &[u8], name: &[u8], opts: &Options) -> Result<Vec<u8>, Error> {
	let n = name_z(name, opts)?;
	let p = path_z(path)?;
	get_with(&os::Native, &p, &n, !opts.follow_symlinks, opts.max_value_len)
}

/// Size-query-then-read with defined behavior under concurrent mutation: an
/// optimistic first read into a 4 KiB buffer (one syscall for small values),
/// then size queries. A value that grew is retried up to `MAX_GET_ATTEMPTS`
/// times, then reported as `Error::Changed`; one that shrank is returned at
/// its actual length.
pub fn get_with(a: &impl Adapter, path: &CStr, name: &CStr, nofollow: bool, max_value_len: usize) -> Result<Vec<u8>, Error> {
	let mut small = [0u8; OPTIMISTIC_READ_LEN];
	match a.read(path, name, nofollow, &mut small) {
		Ok(got) => {
			if got > max_value_len {
				return Err(Error::TooLarge);
			}
			return Ok(small[..got].to_vec());
		}
		Err(Error::BufferTooSmall) => {}
		Err(e) => return Err(e),
	}
	for _ in 0..MAX_GET_ATTEMPTS {
		let expected = a.size(path, name, nofollow)?;
		if expected > max_value_len {
			return Err(Error::TooLarge);
		}
		if expected == 0 {
			return Ok(Vec::new());
		}
		let mut buf = vec![0u8; expected];
		match a.read(path, name, nofollow, &mut buf) {
			Ok(got) => {
				buf.truncate(got);
				return Ok(buf);
			}
			Err(Error::BufferTooSmall) => continue,
			Err(e) => return Err(e),
		}
	}
	Err(Error::Changed)
}

/// Delete the attribute; `Error::Missing` when it was not there.
pub fn remove(path: &[u8], name: &[u8], opts: &Options) -> Result<(), Error> {
	let n = name_z(name, opts)?;
	let p = path_z(path)?;
	os::Native.remove(&p, &n, !opts.follow_symlinks)
}

/// Attribute names, sorted bytewise. In logical mode only names the logical
/// layer can address are returned (see `names::from_native`); raw mode lists
/// everything.
pub fn list(path: &[u8], opts: &Options) -> Result<Vec<Vec<u8>>, Error> {
	let p = path_z(path)?;
	let raw = os::Native.list_raw(&p, !opts.follow_symlinks)?;
	Ok(pack_logical(&raw, OS, opts))
}

/// Pure: turns a native NUL-separated listing into logical names, sorted
/// bytewise. Filesystems return names in arbitrary order (hash order on ZFS,
/// insertion order on ext4, enumeration order on NTFS), so sorting here is
/// what makes listings identical across platforms.
pub fn pack_logical(raw: &[u8], which: names::Os, opts: &Options) -> Vec<Vec<u8>> {
	let mut items: Vec<Vec<u8>> = raw
		.split(|&c| c == 0)
		.filter(|n| !n.is_empty())
		.filter_map(|n| names::from_native(which, n, opts.raw_names))
		.map(<[u8]>::to_vec)
		.collect();
	items.sort();
	items
}

/// Best-effort maximum value size in bytes for the filesystem holding `path`,
/// or -1 when unknown or unbounded.
pub fn limits(path: &[u8]) -> i64 {
	match path_z(path) {
		Ok(p) => os::Native.limits(&p),
		Err(_) => -1,
	}
}

/// Display heuristic for listings: a value is shown as text when it is valid
/// UTF-8 with no control characters other than TAB (so it fits on one line).
pub fn is_display_text(bytes: &[u8]) -> bool {
	!bytes.iter().any(|&c| (c < 0x20 && c != b'\t') || c == 0x7f) && names::is_utf8(bytes)
}

/// Encoded path bytes (raw on POSIX, WTF-8 on Windows) as a std path; `None`
/// for bytes that are not valid WTF-8 on Windows.
pub fn path_from_bytes(bytes: &[u8]) -> Option<std::path::PathBuf> {
	os::path_from_bytes(bytes)
}

/// Well-formed UTF-8 (control characters allowed): whether bytes can go into
/// JSON verbatim. Rejects overlongs, surrogates and code points above U+10FFFF.
pub fn is_utf8(bytes: &[u8]) -> bool {
	names::is_utf8(bytes)
}

#[cfg(test)]
mod tests;
