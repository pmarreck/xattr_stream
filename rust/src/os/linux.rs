//! Linux adapter: the libc xattr calls (thin wrappers over the syscalls the
//! Zig adapter issues directly). The kernel enforces XATTR_SIZE_MAX (64 KiB)
//! per value in the VFS, so `limits` is a constant. ENODATA is ENOATTR here.
use crate::{set_last_os_error, Adapter, Error, MAX_GET_ATTEMPTS, OPTIMISTIC_READ_LEN};
use std::ffi::{c_char, c_int, c_void, CStr};

pub(crate) const OS: crate::names::Os = crate::names::Os::Linux;

extern "C" {
	fn getxattr(path: *const c_char, name: *const c_char, value: *mut c_void, size: usize) -> isize;
	fn lgetxattr(path: *const c_char, name: *const c_char, value: *mut c_void, size: usize) -> isize;
	fn setxattr(path: *const c_char, name: *const c_char, value: *const c_void, size: usize, flags: c_int) -> c_int;
	fn lsetxattr(path: *const c_char, name: *const c_char, value: *const c_void, size: usize, flags: c_int) -> c_int;
	fn removexattr(path: *const c_char, name: *const c_char) -> c_int;
	fn lremovexattr(path: *const c_char, name: *const c_char) -> c_int;
	fn listxattr(path: *const c_char, list: *mut c_char, size: usize) -> isize;
	fn llistxattr(path: *const c_char, list: *mut c_char, size: usize) -> isize;
}

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
pub(crate) const ENAMETOOLONG: i32 = 36;
const ELOOP: i32 = 40;
const ENODATA: i32 = 61;
const EOPNOTSUPP: i32 = 95;
const EDQUOT: i32 = 122;

#[derive(PartialEq)]
enum Ctx {
	Generic,
	Read,
}

fn map_errno(e: i32, ctx: Ctx) -> Error {
	set_last_os_error(e);
	match e {
		ENODATA => Error::Missing,
		EOPNOTSUPP => Error::Unsupported,
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

fn check(rc: isize, ctx: Ctx) -> Result<usize, Error> {
	if rc < 0 {
		Err(map_errno(errno(), ctx))
	} else {
		Ok(rc as usize)
	}
}

fn list_into(path: &CStr, nofollow: bool, buf: &mut [u8]) -> isize {
	let (p, b) = (path.as_ptr(), buf.as_mut_ptr().cast::<c_char>());
	// SAFETY: path is NUL-terminated and buf is valid for buf.len() bytes.
	unsafe {
		if nofollow {
			llistxattr(p, b, buf.len())
		} else {
			listxattr(p, b, buf.len())
		}
	}
}

pub(crate) struct Native;

impl Adapter for Native {
	fn size(&self, path: &CStr, name: &CStr, nofollow: bool) -> Result<usize, Error> {
		let (p, n) = (path.as_ptr(), name.as_ptr());
		// SAFETY: NUL-terminated strings; a zero size never writes to value.
		let rc = unsafe {
			if nofollow {
				lgetxattr(p, n, std::ptr::null_mut(), 0)
			} else {
				getxattr(p, n, std::ptr::null_mut(), 0)
			}
		};
		check(rc, Ctx::Generic)
	}

	fn read(&self, path: &CStr, name: &CStr, nofollow: bool, buf: &mut [u8]) -> Result<usize, Error> {
		let (p, n, b) = (path.as_ptr(), name.as_ptr(), buf.as_mut_ptr().cast::<c_void>());
		// SAFETY: NUL-terminated strings; buf is valid for buf.len() bytes.
		let rc = unsafe {
			if nofollow {
				lgetxattr(p, n, b, buf.len())
			} else {
				getxattr(p, n, b, buf.len())
			}
		};
		check(rc, Ctx::Read)
	}

	fn write(&self, path: &CStr, name: &CStr, nofollow: bool, value: &[u8]) -> Result<(), Error> {
		let (p, n, v) = (path.as_ptr(), name.as_ptr(), value.as_ptr().cast::<c_void>());
		// SAFETY: NUL-terminated strings; value is valid for value.len() bytes.
		let rc = unsafe {
			if nofollow {
				lsetxattr(p, n, v, value.len(), 0)
			} else {
				setxattr(p, n, v, value.len(), 0)
			}
		};
		check(rc as isize, Ctx::Generic).map(|_| ())
	}

	fn remove(&self, path: &CStr, name: &CStr, nofollow: bool) -> Result<(), Error> {
		// SAFETY: NUL-terminated strings.
		let rc = unsafe {
			if nofollow {
				lremovexattr(path.as_ptr(), name.as_ptr())
			} else {
				removexattr(path.as_ptr(), name.as_ptr())
			}
		};
		check(rc as isize, Ctx::Generic).map(|_| ())
	}

	/// One syscall for the common case (few or no attributes); the size-query
	/// loop only runs when the list overflows the optimistic buffer.
	fn list_raw(&self, path: &CStr, nofollow: bool) -> Result<Vec<u8>, Error> {
		let mut small = [0u8; OPTIMISTIC_READ_LEN];
		match check(list_into(path, nofollow, &mut small), Ctx::Read) {
			Ok(got) => return Ok(small[..got].to_vec()),
			Err(Error::BufferTooSmall) => {}
			Err(e) => return Err(e),
		}
		for _ in 0..MAX_GET_ATTEMPTS {
			let expected = check(list_into(path, nofollow, &mut []), Ctx::Generic)?;
			let mut buf = vec![0u8; expected];
			match check(list_into(path, nofollow, &mut buf), Ctx::Read) {
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

	/// XATTR_SIZE_MAX from <linux/limits.h>; enforced by the VFS for every filesystem.
	fn limits(&self, _path: &CStr) -> i64 {
		65536
	}
}
