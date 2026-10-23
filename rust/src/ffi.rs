//! C ABI (FFI) surface: the same `xs_*` functions, constants and contracts as
//! the Zig library's src/ffi.zig, declared by include/xattr_stream.h. Built
//! into the staticlib and cdylib, so the existing C, LuaJIT and Rust consumers
//! link against either implementation unchanged.
//!
//! Buffers are pointer plus byte length; NULL is legal only with length 0.
//! Library-owned buffers (`xs_get`, `xs_list`) are released with
//! `xs_buffer_free`.
#![allow(clippy::missing_safety_doc, non_camel_case_types)]
use crate::{dump, names, walk, Error, Options, Status};
use std::ffi::{c_char, c_int, c_void};

pub const XS_FLAG_NOFOLLOW: u32 = 1 << 0;
pub const XS_FLAG_RAW_NAMES: u32 = 1 << 1;
pub const XS_NAME_OK: c_int = 0;

#[repr(C)]
pub struct xs_options {
	pub flags: u32,
	pub max_value_len: u64,
}

#[repr(C)]
pub struct xs_buffer {
	pub data: *mut u8,
	pub len: usize,
	pub cap: usize,
}

pub type xs_walk_fn = unsafe extern "C" fn(userdata: *mut c_void, path: *const c_char, path_len: usize, kind: c_int, depth: u64, status: c_int) -> c_int;
pub type xs_dump_fn = unsafe extern "C" fn(userdata: *mut c_void, field: c_int, key: *const c_char, key_len: usize, value: *const c_char, value_len: usize) -> c_int;

fn code(e: Error) -> c_int {
	Status::of(Some(e)).code()
}

const OK: c_int = 0;
const INVALID_NAME: c_int = Status::InvalidName as c_int;
const INVALID_PATH: c_int = Status::InvalidPath as c_int;
const INVALID_ARGUMENT: c_int = Status::InvalidArgument as c_int;
const BUFFER_TOO_SMALL: c_int = Status::BufferTooSmall as c_int;

unsafe fn options_from(o: *const xs_options) -> Options {
	let Some(p) = o.as_ref() else { return Options::default() };
	let max = if p.max_value_len == 0 { crate::DEFAULT_MAX_VALUE_LEN } else { usize::try_from(p.max_value_len).unwrap_or(usize::MAX) };
	Options { follow_symlinks: p.flags & XS_FLAG_NOFOLLOW == 0, raw_names: p.flags & XS_FLAG_RAW_NAMES != 0, max_value_len: max }
}

/// (ptr, len) to a slice; NULL is legal only with len 0.
unsafe fn slice<'a, T>(ptr: *const T, len: usize) -> Option<&'a [u8]> {
	if len == 0 {
		return Some(&[]);
	}
	if ptr.is_null() {
		return None;
	}
	Some(std::slice::from_raw_parts(ptr.cast::<u8>(), len))
}

/// Hands a vector to C as an xs_buffer (data NULL when empty).
unsafe fn give(out: &mut xs_buffer, v: Vec<u8>) {
	if v.is_empty() {
		*out = xs_buffer { data: std::ptr::null_mut(), len: 0, cap: 0 };
		return;
	}
	let mut v = std::mem::ManuallyDrop::new(v);
	*out = xs_buffer { data: v.as_mut_ptr(), len: v.len(), cap: v.capacity() };
}

#[no_mangle]
pub unsafe extern "C" fn xs_set(path: *const c_char, path_len: usize, name: *const c_char, name_len: usize, value: *const c_void, value_len: usize, opts: *const xs_options) -> c_int {
	let Some(p) = slice(path, path_len) else { return INVALID_PATH };
	let Some(n) = slice(name, name_len) else { return INVALID_NAME };
	let Some(v) = slice(value, value_len) else { return INVALID_ARGUMENT };
	crate::set(p, n, v, &options_from(opts)).map_or_else(code, |()| OK)
}

#[no_mangle]
pub unsafe extern "C" fn xs_size(path: *const c_char, path_len: usize, name: *const c_char, name_len: usize, opts: *const xs_options, out_len: *mut u64) -> c_int {
	let Some(o) = out_len.as_mut() else { return INVALID_ARGUMENT };
	let Some(p) = slice(path, path_len) else { return INVALID_PATH };
	let Some(n) = slice(name, name_len) else { return INVALID_NAME };
	match crate::size(p, n, &options_from(opts)) {
		Ok(sz) => {
			*o = sz as u64;
			OK
		}
		Err(e) => code(e),
	}
}

#[no_mangle]
pub unsafe extern "C" fn xs_get_into(path: *const c_char, path_len: usize, name: *const c_char, name_len: usize, buf: *mut c_void, buf_cap: usize, opts: *const xs_options, out_len: *mut usize) -> c_int {
	let Some(o) = out_len.as_mut() else { return INVALID_ARGUMENT };
	let Some(p) = slice(path, path_len) else { return INVALID_PATH };
	let Some(n) = slice(name, name_len) else { return INVALID_NAME };
	let dst: &mut [u8] = if buf_cap == 0 {
		&mut []
	} else if buf.is_null() {
		return INVALID_ARGUMENT;
	} else {
		std::slice::from_raw_parts_mut(buf.cast::<u8>(), buf_cap)
	};
	match crate::get_into(p, n, dst, &options_from(opts)) {
		Ok(got) => {
			*o = got;
			OK
		}
		Err(e) => code(e),
	}
}

#[no_mangle]
pub unsafe extern "C" fn xs_get(path: *const c_char, path_len: usize, name: *const c_char, name_len: usize, opts: *const xs_options, out: *mut xs_buffer) -> c_int {
	let Some(o) = out.as_mut() else { return INVALID_ARGUMENT };
	*o = xs_buffer { data: std::ptr::null_mut(), len: 0, cap: 0 };
	let Some(p) = slice(path, path_len) else { return INVALID_PATH };
	let Some(n) = slice(name, name_len) else { return INVALID_NAME };
	match crate::get(p, n, &options_from(opts)) {
		Ok(v) => {
			give(o, v);
			OK
		}
		Err(e) => code(e),
	}
}

#[no_mangle]
pub unsafe extern "C" fn xs_remove(path: *const c_char, path_len: usize, name: *const c_char, name_len: usize, opts: *const xs_options) -> c_int {
	let Some(p) = slice(path, path_len) else { return INVALID_PATH };
	let Some(n) = slice(name, name_len) else { return INVALID_NAME };
	crate::remove(p, n, &options_from(opts)).map_or_else(code, |()| OK)
}

#[no_mangle]
pub unsafe extern "C" fn xs_list(path: *const c_char, path_len: usize, opts: *const xs_options, out: *mut xs_buffer, out_count: *mut usize) -> c_int {
	let Some(o) = out.as_mut() else { return INVALID_ARGUMENT };
	let Some(c) = out_count.as_mut() else { return INVALID_ARGUMENT };
	*o = xs_buffer { data: std::ptr::null_mut(), len: 0, cap: 0 };
	*c = 0;
	let Some(p) = slice(path, path_len) else { return INVALID_PATH };
	match crate::list(p, &options_from(opts)) {
		Ok(names) => {
			*c = names.len();
			let mut packed = Vec::with_capacity(names.iter().map(|n| n.len() + 1).sum());
			for n in names {
				packed.extend_from_slice(&n);
				packed.push(0);
			}
			give(o, packed);
			OK
		}
		Err(e) => code(e),
	}
}

#[no_mangle]
pub unsafe extern "C" fn xs_buffer_free(buf: *mut xs_buffer) {
	let Some(b) = buf.as_mut() else { return };
	if !b.data.is_null() {
		drop(Vec::from_raw_parts(b.data, b.len, b.cap));
	}
	*b = xs_buffer { data: std::ptr::null_mut(), len: 0, cap: 0 };
}

#[no_mangle]
pub unsafe extern "C" fn xs_limits(path: *const c_char, path_len: usize) -> i64 {
	match slice(path, path_len) {
		Some(p) => crate::limits(p),
		None => -1,
	}
}

#[no_mangle]
pub unsafe extern "C" fn xs_native_name(name: *const c_char, name_len: usize, opts: *const xs_options, out: *mut c_char, out_cap: usize, out_len: *mut usize) -> c_int {
	let Some(o) = out_len.as_mut() else { return INVALID_ARGUMENT };
	let Some(n) = slice(name, name_len) else { return INVALID_NAME };
	let native = match crate::native_name(n, &options_from(opts)) {
		Ok(v) => v,
		Err(e) => return code(e),
	};
	*o = native.len();
	if out_cap < native.len() + 1 {
		return BUFFER_TOO_SMALL;
	}
	if out.is_null() {
		return INVALID_ARGUMENT;
	}
	std::ptr::copy_nonoverlapping(native.as_ptr(), out.cast::<u8>(), native.len());
	*out.add(native.len()) = 0;
	OK
}

/// Why a name would be rejected under `opts`, as an xs_name_rejection code.
#[no_mangle]
pub unsafe extern "C" fn xs_validate_name(name: *const c_char, name_len: usize, opts: *const xs_options) -> c_int {
	let Some(n) = slice(name, name_len) else { return names::Rejection::InvalidNative as c_int };
	names::classify(crate::OS, n, options_from(opts).raw_names).map_or(XS_NAME_OK, |r| r as c_int)
}

fn rejection_from_code(code: c_int) -> Option<names::Rejection> {
	use names::Rejection::*;
	[Empty, TooLong, ControlChar, ForbiddenChar, Reserved, NotUtf8, EdgeWhitespaceOrDot, LinuxNamespace, InvalidNative].into_iter().find(|r| *r as c_int == code)
}

/// Static NUL-terminated copies of the strings the ABI returns.
macro_rules! cstr {
	($s:expr) => {
		concat!($s, "\0").as_ptr().cast::<c_char>()
	};
}

#[no_mangle]
pub extern "C" fn xs_name_rejection_name(code: c_int) -> *const c_char {
	match code {
		0 => cstr!("XS_NAME_OK"),
		1 => cstr!("XS_NAME_EMPTY"),
		2 => cstr!("XS_NAME_TOO_LONG"),
		3 => cstr!("XS_NAME_CONTROL_CHAR"),
		4 => cstr!("XS_NAME_FORBIDDEN_CHAR"),
		5 => cstr!("XS_NAME_RESERVED"),
		6 => cstr!("XS_NAME_NOT_UTF8"),
		7 => cstr!("XS_NAME_EDGE_WHITESPACE_OR_DOT"),
		8 => cstr!("XS_NAME_LINUX_NAMESPACE"),
		9 => cstr!("XS_NAME_INVALID_NATIVE"),
		_ => cstr!("XS_NAME_UNKNOWN"),
	}
}

#[no_mangle]
pub extern "C" fn xs_name_rejection_message(code: c_int) -> *const c_char {
	use names::Rejection::*;
	match rejection_from_code(code) {
		None if code == XS_NAME_OK => cstr!("name is acceptable"),
		None => cstr!("unknown name rejection code"),
		Some(Empty) => cstr!("name is empty"),
		Some(TooLong) => cstr!("name is longer than 127 bytes"),
		Some(ControlChar) => cstr!("name contains a control character or NUL"),
		Some(ForbiddenChar) => cstr!("name contains one of / \\ : * ? \" < > |"),
		Some(Reserved) => cstr!("name is reserved by the OS ($..., com.apple..., Zone.Identifier)"),
		Some(NotUtf8) => cstr!("name is not valid UTF-8"),
		Some(EdgeWhitespaceOrDot) => cstr!("name has leading/trailing space or a trailing dot"),
		Some(LinuxNamespace) => cstr!("the user. prefix is reserved: on Linux the library applies the user. namespace itself, so pass the name without it (or use raw names)"),
		Some(InvalidNative) => cstr!("native name is empty, too long, contains NUL, or contains a path character"),
	}
}

#[no_mangle]
pub unsafe extern "C" fn xs_is_display_text(bytes: *const c_void, len: usize) -> c_int {
	slice(bytes, len).map_or(0, |b| c_int::from(crate::is_display_text(b)))
}

#[no_mangle]
pub unsafe extern "C" fn xs_is_utf8(bytes: *const c_void, len: usize) -> c_int {
	slice(bytes, len).map_or(0, |b| c_int::from(crate::is_utf8(b)))
}

/// Walk a tree in breadth-first (0) or depth-first (1) order; max_depth < 0
/// is unlimited. XS_OK, or the status of the root when it cannot be inspected.
#[no_mangle]
pub unsafe extern "C" fn xs_walk(path: *const c_char, path_len: usize, order: c_int, max_depth: i64, cb: Option<xs_walk_fn>, userdata: *mut c_void) -> c_int {
	let Some(p) = slice(path, path_len) else { return INVALID_PATH };
	let Some(f) = cb else { return INVALID_ARGUMENT };
	let opts = walk::Options {
		order: if order == 1 { walk::Order::DepthFirst } else { walk::Order::BreadthFirst },
		max_depth: usize::try_from(max_depth).ok(),
	};
	walk::walk(&walk::FsLister, p, opts, |v| f(userdata, v.path.as_ptr().cast(), v.path.len(), v.kind as c_int, v.depth as u64, v.status.code()) == 0).map_or_else(code, |()| OK)
}

/// Parse one `dump --json` line, calling `cb` per field; XS_INVALID_ARGUMENT
/// for a malformed line or a NULL callback.
#[no_mangle]
pub unsafe extern "C" fn xs_parse_dump_line(line: *const c_char, len: usize, cb: Option<xs_dump_fn>, userdata: *mut c_void) -> c_int {
	let Some(l) = slice(line, len) else { return INVALID_ARGUMENT };
	let Some(f) = cb else { return INVALID_ARGUMENT };
	dump::parse_line(l, |field, k, v| f(userdata, field as c_int, k.as_ptr().cast(), k.len(), v.as_ptr().cast(), v.len()) == 0).map_or(INVALID_ARGUMENT, |()| OK)
}

#[no_mangle]
pub unsafe extern "C" fn xs_is_contained_relative_path(path: *const c_char, len: usize) -> c_int {
	slice(path, len).map_or(0, |p| c_int::from(dump::is_contained_relative_path(p)))
}

#[no_mangle]
pub unsafe extern "C" fn xs_is_absolute_path(path: *const c_char, len: usize) -> c_int {
	slice(path, len).map_or(0, |p| c_int::from(dump::is_absolute_path(p)))
}

#[no_mangle]
pub extern "C" fn xs_status_name(s: c_int) -> *const c_char {
	match s {
		0 => cstr!("XS_OK"),
		1 => cstr!("XS_MISSING"),
		2 => cstr!("XS_UNSUPPORTED"),
		3 => cstr!("XS_READ_ONLY"),
		4 => cstr!("XS_PERMISSION"),
		5 => cstr!("XS_TOO_LARGE"),
		6 => cstr!("XS_NOT_FOUND"),
		7 => cstr!("XS_INVALID_NAME"),
		8 => cstr!("XS_INVALID_PATH"),
		9 => cstr!("XS_CHANGED"),
		10 => cstr!("XS_BUFFER_TOO_SMALL"),
		11 => cstr!("XS_OUT_OF_MEMORY"),
		12 => cstr!("XS_IO"),
		13 => cstr!("XS_INVALID_ARGUMENT"),
		_ => cstr!("XS_UNKNOWN"),
	}
}

#[no_mangle]
pub extern "C" fn xs_last_os_error() -> i32 {
	crate::last_os_error()
}

#[no_mangle]
pub extern "C" fn xs_version() -> *const c_char {
	concat!(env!("CARGO_PKG_VERSION"), "\0").as_ptr().cast()
}

#[no_mangle]
pub extern "C" fn xs_target() -> *const c_char {
	match crate::PLATFORM {
		"linux-amd64" => cstr!("linux-amd64"),
		"linux-arm64" => cstr!("linux-arm64"),
		"macos-amd64" => cstr!("macos-amd64"),
		"macos-arm64" => cstr!("macos-arm64"),
		"mswin-amd64" => cstr!("mswin-amd64"),
		_ => cstr!("mswin-arm64"),
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	use std::ffi::CStr;

	#[test]
	fn static_strings_agree_with_the_rust_names() {
		for code in -1..15 {
			// SAFETY: every returned pointer is a static NUL-terminated string.
			let s = unsafe { CStr::from_ptr(xs_status_name(code)) }.to_str().unwrap();
			assert_eq!(s, crate::status_name(code));
		}
		for r in 1..10 {
			let msg = unsafe { CStr::from_ptr(xs_name_rejection_message(r)) }.to_str().unwrap();
			assert_eq!(msg, names::rejection_message(rejection_from_code(r).unwrap()));
		}
		assert_eq!(unsafe { CStr::from_ptr(xs_target()) }.to_str().unwrap(), crate::PLATFORM);
		assert_eq!(unsafe { CStr::from_ptr(xs_version()) }.to_str().unwrap(), crate::VERSION);
	}

	#[test]
	fn null_pointers_follow_the_length_rule() {
		unsafe {
			assert_eq!(xs_set(std::ptr::null(), 1, c"k".as_ptr(), 1, std::ptr::null(), 0, std::ptr::null()), INVALID_PATH);
			assert_eq!(xs_set(c"p".as_ptr(), 1, std::ptr::null(), 1, std::ptr::null(), 0, std::ptr::null()), INVALID_NAME);
			assert_eq!(xs_set(c"p".as_ptr(), 1, c"k".as_ptr(), 1, std::ptr::null(), 1, std::ptr::null()), INVALID_ARGUMENT);
			assert_eq!(xs_size(c"p".as_ptr(), 1, c"k".as_ptr(), 1, std::ptr::null(), std::ptr::null_mut()), INVALID_ARGUMENT);
			assert_eq!(xs_is_utf8(std::ptr::null(), 0), 1);
			assert_eq!(xs_is_display_text(std::ptr::null(), 0), 1);
			assert_eq!(xs_limits(std::ptr::null(), 0), -1);
			assert_eq!(xs_walk(c"r".as_ptr(), 1, 0, -1, None, std::ptr::null_mut()), INVALID_ARGUMENT);
			assert_eq!(xs_parse_dump_line(c"{}".as_ptr(), 2, None, std::ptr::null_mut()), INVALID_ARGUMENT);
			let mut b = xs_buffer { data: std::ptr::null_mut(), len: 0, cap: 0 };
			xs_buffer_free(&mut b);
			xs_buffer_free(std::ptr::null_mut());
		}
	}
}
