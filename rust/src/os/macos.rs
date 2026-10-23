//! macOS adapter: libSystem xattr calls with the Darwin (position, options)
//! signature. XATTR_NOFOLLOW selects the symlink itself. ENOATTR is distinct
//! from ENODATA here.
use crate::{set_last_os_error, Adapter, Error, MAX_GET_ATTEMPTS, OPTIMISTIC_READ_LEN};
use std::ffi::{c_char, c_int, c_long, c_void, CStr};

pub(crate) const OS: crate::names::Os = crate::names::Os::Macos;

extern "C" {
	fn getxattr(path: *const c_char, name: *const c_char, value: *mut c_void, size: usize, position: u32, options: c_int) -> isize;
	fn setxattr(path: *const c_char, name: *const c_char, value: *const c_void, size: usize, position: u32, options: c_int) -> c_int;
	fn removexattr(path: *const c_char, name: *const c_char, options: c_int) -> c_int;
	fn listxattr(path: *const c_char, namebuf: *mut c_char, size: usize, options: c_int) -> isize;
	fn pathconf(path: *const c_char, name: c_int) -> c_long;
}

const XATTR_NOFOLLOW: c_int = 0x0001;
/// <unistd.h>: _PC_XATTR_SIZE_BITS, number of bits in the maximum xattr size.
const PC_XATTR_SIZE_BITS: c_int = 26;

const EPERM: i32 = 1;
const ENOENT: i32 = 2;
const E2BIG: i32 = 7;
const ENOMEM: i32 = 12;
const EACCES: i32 = 13;
pub(crate) const ENOTDIR: i32 = 20;
const EINVAL: i32 = 22;
const EFBIG: i32 = 27;
const ENOSPC: i32 = 28;
const EROFS: i32 = 30;
const ERANGE: i32 = 34;
/// What getxattr(2) documents for a volume without attribute support.
const ENOTSUP: i32 = 45;
const ELOOP: i32 = 62;
pub(crate) const ENAMETOOLONG: i32 = 63;
const EDQUOT: i32 = 69;
const ENOATTR: i32 = 93;
const EOPNOTSUPP: i32 = 102;

#[derive(PartialEq)]
enum Ctx {
	Generic,
	Read,
}

fn map_errno(e: i32, ctx: Ctx) -> Error {
	set_last_os_error(e);
	match e {
		ENOATTR => Error::Missing,
		ENOTSUP | EOPNOTSUPP => Error::Unsupported,
		EROFS => Error::ReadOnly,
		EACCES | EPERM => Error::Permission,
		E2BIG | ENOSPC | EDQUOT | EFBIG => Error::TooLarge,
		ERANGE if ctx == Ctx::Read => Error::BufferTooSmall,
		ERANGE => Error::TooLarge,
		ENOENT | ENOTDIR | ELOOP => Error::NotFound,
		ENAMETOOLONG | EINVAL => Error::InvalidName,
		ENOMEM => Error::OutOfMemory,
		_ => Error::Io,
	}
}

fn errno() -> i32 {
	std::io::Error::last_os_error().raw_os_error().unwrap_or(0)
}

fn opts(nofollow: bool) -> c_int {
	if nofollow {
		XATTR_NOFOLLOW
	} else {
		0
	}
}

fn list_into(path: &CStr, nofollow: bool, buf: &mut [u8]) -> isize {
	let b = if buf.is_empty() { std::ptr::null_mut() } else { buf.as_mut_ptr().cast::<c_char>() };
	// SAFETY: path is NUL-terminated and buf is valid for buf.len() bytes.
	unsafe { listxattr(path.as_ptr(), b, buf.len(), opts(nofollow)) }
}

pub(crate) struct Native;

impl Adapter for Native {
	fn size(&self, path: &CStr, name: &CStr, nofollow: bool) -> Result<usize, Error> {
		// SAFETY: NUL-terminated strings; a null value buffer is a size query.
		let rc = unsafe { getxattr(path.as_ptr(), name.as_ptr(), std::ptr::null_mut(), 0, 0, opts(nofollow)) };
		if rc < 0 {
			return Err(map_errno(errno(), Ctx::Generic));
		}
		Ok(rc as usize)
	}

	fn read(&self, path: &CStr, name: &CStr, nofollow: bool, buf: &mut [u8]) -> Result<usize, Error> {
		// SAFETY: NUL-terminated strings; buf is valid for buf.len() bytes.
		let rc = unsafe { getxattr(path.as_ptr(), name.as_ptr(), buf.as_mut_ptr().cast::<c_void>(), buf.len(), 0, opts(nofollow)) };
		if rc < 0 {
			return Err(map_errno(errno(), Ctx::Read));
		}
		Ok(rc as usize)
	}

	fn write(&self, path: &CStr, name: &CStr, nofollow: bool, value: &[u8]) -> Result<(), Error> {
		// SAFETY: NUL-terminated strings; value is valid for value.len() bytes.
		let rc = unsafe { setxattr(path.as_ptr(), name.as_ptr(), value.as_ptr().cast::<c_void>(), value.len(), 0, opts(nofollow)) };
		if rc != 0 {
			return Err(map_errno(errno(), Ctx::Generic));
		}
		Ok(())
	}

	fn remove(&self, path: &CStr, name: &CStr, nofollow: bool) -> Result<(), Error> {
		// SAFETY: NUL-terminated strings.
		if unsafe { removexattr(path.as_ptr(), name.as_ptr(), opts(nofollow)) } != 0 {
			return Err(map_errno(errno(), Ctx::Generic));
		}
		Ok(())
	}

	/// One syscall for the common case; the size-query loop only runs when the
	/// list overflows the optimistic buffer (ERANGE).
	fn list_raw(&self, path: &CStr, nofollow: bool) -> Result<Vec<u8>, Error> {
		let mut small = [0u8; OPTIMISTIC_READ_LEN];
		let first = list_into(path, nofollow, &mut small);
		if first >= 0 {
			return Ok(small[..first as usize].to_vec());
		}
		let first_err = errno();
		if first_err != ERANGE {
			return Err(map_errno(first_err, Ctx::Generic));
		}
		for _ in 0..MAX_GET_ATTEMPTS {
			let q = list_into(path, nofollow, &mut []);
			if q < 0 {
				return Err(map_errno(errno(), Ctx::Generic));
			}
			let mut buf = vec![0u8; q as usize];
			let rc = list_into(path, nofollow, &mut buf);
			if rc < 0 {
				let e = errno();
				if e == ERANGE {
					continue;
				}
				return Err(map_errno(e, Ctx::Read));
			}
			buf.truncate(rc as usize);
			return Ok(buf);
		}
		Err(Error::Changed)
	}

	/// pathconf(_PC_XATTR_SIZE_BITS) gives the bit width of the maximum value
	/// size on the volume; -1 when the volume does not report it.
	fn limits(&self, path: &CStr) -> i64 {
		// SAFETY: NUL-terminated string.
		let bits = unsafe { pathconf(path.as_ptr(), PC_XATTR_SIZE_BITS) };
		if bits <= 0 || bits >= 63 {
			return -1;
		}
		(1i64 << bits) - 1
	}
}
