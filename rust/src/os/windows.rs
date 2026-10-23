//! Windows adapter: NTFS alternate data streams (`path:name`), chosen over
//! NTFS extended attributes as in src/windows.zig: streams hold any size, are
//! visible (`dir /r`), survive NTFS-to-NTFS copies and are what Windows itself
//! uses (Zone.Identifier). Writers open a stream exclusively and readers deny
//! writers, so a reader never sees a stream between truncation and the last
//! byte written; sharing violations are retried with a bounded backoff.
use crate::{set_last_os_error, Adapter, Error};
use std::ffi::{c_int, c_void, CStr};

pub(crate) const OS: crate::names::Os = crate::names::Os::Windows;

type Handle = *mut c_void;
type Dword = u32;
type Bool = c_int;

const MAX_PATH: usize = 260;

#[repr(C)]
struct Win32FindStreamData {
	stream_size: i64,
	c_stream_name: [u16; MAX_PATH + 36],
}

#[link(name = "kernel32")]
extern "system" {
	fn CreateFileW(name: *const u16, access: Dword, share: Dword, security: *mut c_void, disposition: Dword, flags: Dword, template: Handle) -> Handle;
	fn ReadFile(h: Handle, buf: *mut u8, len: Dword, read: *mut Dword, overlapped: *mut c_void) -> Bool;
	fn WriteFile(h: Handle, buf: *const u8, len: Dword, written: *mut Dword, overlapped: *mut c_void) -> Bool;
	fn CloseHandle(h: Handle) -> Bool;
	fn DeleteFileW(name: *const u16) -> Bool;
	fn GetFileSizeEx(h: Handle, size: *mut i64) -> Bool;
	fn GetFileAttributesW(name: *const u16) -> Dword;
	fn GetLastError() -> Dword;
	fn FindFirstStreamW(name: *const u16, info_level: c_int, data: *mut Win32FindStreamData, flags: Dword) -> Handle;
	fn FindNextStreamW(h: Handle, data: *mut Win32FindStreamData) -> Bool;
	fn FindClose(h: Handle) -> Bool;
	fn Sleep(ms: Dword);
}

const INVALID_HANDLE_VALUE: Handle = usize::MAX as Handle;
const INVALID_FILE_ATTRIBUTES: Dword = 0xFFFF_FFFF;
const GENERIC_READ: Dword = 0x8000_0000;
const GENERIC_WRITE: Dword = 0x4000_0000;
const FILE_READ_ATTRIBUTES: Dword = 0x0080;
const FILE_SHARE_READ: Dword = 0x1;
const FILE_SHARE_ALL: Dword = 0x1 | 0x2 | 0x4;
const SHARE_WRITER: Dword = 0;
const SHARE_READER: Dword = FILE_SHARE_READ;
/// Bounded wait for a stream another handle holds: up to about 2 s.
const SHARING_RETRIES: usize = 200;
const SHARING_BACKOFF_MS: Dword = 10;
const CREATE_ALWAYS: Dword = 2;
const OPEN_EXISTING: Dword = 3;
const FILE_ATTRIBUTE_NORMAL: Dword = 0x80;
const FILE_FLAG_BACKUP_SEMANTICS: Dword = 0x0200_0000;
const FILE_FLAG_OPEN_REPARSE_POINT: Dword = 0x0020_0000;

const ERROR_INVALID_FUNCTION: Dword = 1;
const ERROR_FILE_NOT_FOUND: Dword = 2;
const ERROR_PATH_NOT_FOUND: Dword = 3;
const ERROR_ACCESS_DENIED: Dword = 5;
const ERROR_NOT_ENOUGH_MEMORY: Dword = 8;
const ERROR_WRITE_PROTECT: Dword = 19;
const ERROR_SHARING_VIOLATION: Dword = 32;
const ERROR_HANDLE_EOF: Dword = 38;
const ERROR_HANDLE_DISK_FULL: Dword = 39;
const ERROR_NOT_SUPPORTED: Dword = 50;
const ERROR_DISK_FULL: Dword = 112;
const ERROR_INVALID_NAME: Dword = 123;
const ERROR_FILE_TOO_LARGE: Dword = 223;
const ERROR_EAS_NOT_SUPPORTED: Dword = 282;

/// Longest path the NT object manager accepts, in UTF-16 units.
const MAX_WPATH: usize = 32767;

#[derive(PartialEq)]
enum Ctx {
	Path,
	Attr,
	Read,
}

/// FILE/PATH_NOT_FOUND means the base path is gone when `ctx` is `Path`,
/// otherwise that the stream is absent. INVALID_NAME after our own
/// validation means the volume has no stream support (FAT/exFAT).
fn map_win(code: Dword, ctx: Ctx) -> Error {
	set_last_os_error(code as i32);
	match code {
		ERROR_FILE_NOT_FOUND | ERROR_PATH_NOT_FOUND if ctx == Ctx::Path => Error::NotFound,
		ERROR_FILE_NOT_FOUND | ERROR_PATH_NOT_FOUND => Error::Missing,
		ERROR_ACCESS_DENIED => Error::Permission,
		ERROR_WRITE_PROTECT => Error::ReadOnly,
		ERROR_HANDLE_DISK_FULL | ERROR_DISK_FULL | ERROR_FILE_TOO_LARGE => Error::TooLarge,
		ERROR_INVALID_FUNCTION | ERROR_NOT_SUPPORTED | ERROR_INVALID_NAME | ERROR_EAS_NOT_SUPPORTED => Error::Unsupported,
		ERROR_NOT_ENOUGH_MEMORY => Error::OutOfMemory,
		_ => Error::Io,
	}
}

/// WTF-8 (UTF-8 that may encode lone surrogates) to UTF-16 code units, as
/// std.unicode.wtf8ToWtf16Le does; `None` for anything else.
pub(crate) fn wtf8_to_utf16(s: &[u8]) -> Option<Vec<u16>> {
	let mut out = Vec::with_capacity(s.len());
	let mut i = 0;
	while i < s.len() {
		let b0 = s[i];
		let cont = |j: usize, lo: u8, hi: u8| s.get(i + j).copied().filter(|&c| (lo..=hi).contains(&c));
		let (cp, n) = match b0 {
			0x00..=0x7F => (u32::from(b0), 1),
			0xC2..=0xDF => (u32::from(b0 & 0x1F) << 6 | u32::from(cont(1, 0x80, 0xBF)? & 0x3F), 2),
			0xE0..=0xEF => {
				let lo = if b0 == 0xE0 { 0xA0 } else { 0x80 };
				let c1 = cont(1, lo, 0xBF)?;
				let c2 = cont(2, 0x80, 0xBF)?;
				(u32::from(b0 & 0x0F) << 12 | u32::from(c1 & 0x3F) << 6 | u32::from(c2 & 0x3F), 3)
			}
			0xF0..=0xF4 => {
				let (lo, hi) = match b0 {
					0xF0 => (0x90, 0xBF),
					0xF4 => (0x80, 0x8F),
					_ => (0x80, 0xBF),
				};
				let c1 = cont(1, lo, hi)?;
				let c2 = cont(2, 0x80, 0xBF)?;
				let c3 = cont(3, 0x80, 0xBF)?;
				(u32::from(b0 & 0x07) << 18 | u32::from(c1 & 0x3F) << 12 | u32::from(c2 & 0x3F) << 6 | u32::from(c3 & 0x3F), 4)
			}
			_ => return None,
		};
		if cp >= 0x10000 {
			let v = cp - 0x10000;
			out.push(0xD800 | (v >> 10) as u16);
			out.push(0xDC00 | (v & 0x3FF) as u16);
		} else {
			out.push(cp as u16);
		}
		i += n;
	}
	Some(out)
}

/// UTF-16 code units to WTF-8; unpaired surrogates become 3-byte sequences.
pub(crate) fn utf16_to_wtf8(units: &[u16]) -> Vec<u8> {
	let mut out = Vec::with_capacity(units.len());
	for r in char::decode_utf16(units.iter().copied()) {
		let cp = match r {
			Ok(c) => u32::from(c),
			Err(e) => u32::from(e.unpaired_surrogate()),
		};
		match cp {
			0..=0x7F => out.push(cp as u8),
			0x80..=0x7FF => out.extend_from_slice(&[0xC0 | (cp >> 6) as u8, 0x80 | (cp & 0x3F) as u8]),
			0x800..=0xFFFF => out.extend_from_slice(&[0xE0 | (cp >> 12) as u8, 0x80 | ((cp >> 6) & 0x3F) as u8, 0x80 | (cp & 0x3F) as u8]),
			_ => out.extend_from_slice(&[0xF0 | (cp >> 18) as u8, 0x80 | ((cp >> 12) & 0x3F) as u8, 0x80 | ((cp >> 6) & 0x3F) as u8, 0x80 | (cp & 0x3F) as u8]),
		}
	}
	out
}

pub(crate) fn path_from_bytes(bytes: &[u8]) -> Option<std::path::PathBuf> {
	use std::os::windows::ffi::OsStringExt;
	Some(std::ffi::OsString::from_wide(&wtf8_to_utf16(bytes)?).into())
}

pub(crate) fn bytes_from_os(s: &std::ffi::OsStr) -> Vec<u8> {
	s.as_encoded_bytes().to_vec()
}

fn to_wide(path: &CStr) -> Result<Vec<u16>, Error> {
	let mut w = wtf8_to_utf16(path.to_bytes()).ok_or(Error::InvalidPath)?;
	if w.len() > MAX_WPATH {
		return Err(Error::InvalidPath);
	}
	w.push(0);
	Ok(w)
}

/// `path:name` in UTF-16. The name was validated to exclude `:` `\` `/`, so
/// the only separator introduced here is the one stream delimiter.
fn stream_path(path: &CStr, name: &CStr) -> Result<Vec<u16>, Error> {
	let mut w = wtf8_to_utf16(path.to_bytes()).ok_or(Error::InvalidPath)?;
	if w.len() + 1 >= MAX_WPATH {
		return Err(Error::InvalidPath);
	}
	w.push(u16::from(b':'));
	w.extend(wtf8_to_utf16(name.to_bytes()).ok_or(Error::InvalidName)?);
	if w.len() > MAX_WPATH {
		return Err(Error::InvalidName);
	}
	w.push(0);
	Ok(w)
}

/// The base file or directory must exist: CREATE_ALWAYS on a stream would
/// otherwise create the file, and a missing stream would be
/// indistinguishable from a missing path.
fn require_base(path: &CStr) -> Result<(), Error> {
	let w = to_wide(path)?;
	// SAFETY: NUL-terminated UTF-16 string.
	if unsafe { GetFileAttributesW(w.as_ptr()) } == INVALID_FILE_ATTRIBUTES {
		return Err(map_win(unsafe { GetLastError() }, Ctx::Path));
	}
	Ok(())
}

struct Owned(Handle);

impl Drop for Owned {
	fn drop(&mut self) {
		// SAFETY: a handle this module opened and has not closed.
		unsafe { CloseHandle(self.0) };
	}
}

/// Opens `path:name`, retrying a sharing violation (another reader or writer
/// holds the stream) with a short bounded backoff.
fn open_stream(path: &CStr, name: &CStr, nofollow: bool, access: Dword, share: Dword, disposition: Dword) -> Result<Owned, Error> {
	require_base(path)?;
	let ws = stream_path(path, name)?;
	let mut flags = FILE_ATTRIBUTE_NORMAL | FILE_FLAG_BACKUP_SEMANTICS;
	if nofollow {
		flags |= FILE_FLAG_OPEN_REPARSE_POINT;
	}
	let mut attempt = 0;
	loop {
		// SAFETY: NUL-terminated UTF-16 path; null security and template.
		let h = unsafe { CreateFileW(ws.as_ptr(), access, share, std::ptr::null_mut(), disposition, flags, std::ptr::null_mut()) };
		if h != INVALID_HANDLE_VALUE {
			return Ok(Owned(h));
		}
		let code = unsafe { GetLastError() };
		if code != ERROR_SHARING_VIOLATION || attempt + 1 >= SHARING_RETRIES {
			return Err(map_win(code, Ctx::Attr));
		}
		unsafe { Sleep(if attempt == 0 { 0 } else { SHARING_BACKOFF_MS }) };
		attempt += 1;
	}
}

fn handle_size(h: &Owned) -> Result<usize, Error> {
	let mut sz = 0i64;
	// SAFETY: open handle, valid out-pointer.
	if unsafe { GetFileSizeEx(h.0, &mut sz) } == 0 {
		return Err(map_win(unsafe { GetLastError() }, Ctx::Attr));
	}
	Ok(sz as usize)
}

/// `:name:$DATA` -> `name`; the unnamed data stream (`::$DATA`) and other
/// stream types are skipped.
fn parse_stream_name(w: &[u16]) -> Option<&[u16]> {
	let rest = w.strip_prefix(&[u16::from(b':')])?;
	let end = rest.iter().position(|&c| c == u16::from(b':')).unwrap_or(rest.len());
	if end == 0 {
		return None;
	}
	let suffix: Vec<u16> = ":$DATA".encode_utf16().collect();
	if rest[end..] != suffix[..] {
		return None;
	}
	Some(&rest[..end])
}

pub(crate) struct Native;

impl Adapter for Native {
	fn size(&self, path: &CStr, name: &CStr, nofollow: bool) -> Result<usize, Error> {
		let h = open_stream(path, name, nofollow, FILE_READ_ATTRIBUTES, FILE_SHARE_ALL, OPEN_EXISTING)?;
		handle_size(&h)
	}

	fn read(&self, path: &CStr, name: &CStr, nofollow: bool, buf: &mut [u8]) -> Result<usize, Error> {
		let h = open_stream(path, name, nofollow, GENERIC_READ, SHARE_READER, OPEN_EXISTING)?;
		let expected = handle_size(&h)?;
		if expected > buf.len() {
			return Err(Error::BufferTooSmall);
		}
		let mut total = 0;
		while total < expected {
			let chunk = (expected - total).min(Dword::MAX as usize) as Dword;
			let mut got: Dword = 0;
			// SAFETY: buf has room for `chunk` bytes past `total`.
			if unsafe { ReadFile(h.0, buf.as_mut_ptr().add(total), chunk, &mut got, std::ptr::null_mut()) } == 0 {
				return Err(map_win(unsafe { GetLastError() }, Ctx::Read));
			}
			if got == 0 {
				break;
			}
			total += got as usize;
		}
		Ok(total)
	}

	fn write(&self, path: &CStr, name: &CStr, nofollow: bool, value: &[u8]) -> Result<(), Error> {
		let h = open_stream(path, name, nofollow, GENERIC_WRITE, SHARE_WRITER, CREATE_ALWAYS)?;
		let mut total = 0;
		while total < value.len() {
			let chunk = (value.len() - total).min(Dword::MAX as usize) as Dword;
			let mut written: Dword = 0;
			// SAFETY: value has `chunk` bytes past `total`.
			if unsafe { WriteFile(h.0, value.as_ptr().add(total), chunk, &mut written, std::ptr::null_mut()) } == 0 {
				return Err(map_win(unsafe { GetLastError() }, Ctx::Attr));
			}
			if written == 0 {
				return Err(map_win(ERROR_DISK_FULL, Ctx::Attr));
			}
			total += written as usize;
		}
		Ok(())
	}

	fn remove(&self, path: &CStr, name: &CStr, _nofollow: bool) -> Result<(), Error> {
		// DeleteFileW never follows reparse points.
		require_base(path)?;
		let ws = stream_path(path, name)?;
		let mut attempt = 0;
		// SAFETY: NUL-terminated UTF-16 path.
		while unsafe { DeleteFileW(ws.as_ptr()) } == 0 {
			let code = unsafe { GetLastError() };
			if code != ERROR_SHARING_VIOLATION || attempt + 1 >= SHARING_RETRIES {
				return Err(map_win(code, Ctx::Attr));
			}
			unsafe { Sleep(if attempt == 0 { 0 } else { SHARING_BACKOFF_MS }) };
			attempt += 1;
		}
		Ok(())
	}

	fn list_raw(&self, path: &CStr, _nofollow: bool) -> Result<Vec<u8>, Error> {
		// FindFirstStreamW has no reparse-point flag; it enumerates the resolved path.
		require_base(path)?;
		let wp = to_wide(path)?;
		let mut data = Win32FindStreamData { stream_size: 0, c_stream_name: [0; MAX_PATH + 36] };
		// SAFETY: NUL-terminated UTF-16 path, valid out-pointer.
		let h = unsafe { FindFirstStreamW(wp.as_ptr(), 0, &mut data, 0) };
		if h == INVALID_HANDLE_VALUE {
			let e = unsafe { GetLastError() };
			if e == ERROR_HANDLE_EOF {
				return Ok(Vec::new());
			}
			return Err(map_win(e, Ctx::Path));
		}
		struct Find(Handle);
		impl Drop for Find {
			fn drop(&mut self) {
				// SAFETY: a find handle this function opened.
				unsafe { FindClose(self.0) };
			}
		}
		let find = Find(h);
		let mut out = Vec::new();
		loop {
			let len = data.c_stream_name.iter().position(|&c| c == 0).unwrap_or(data.c_stream_name.len());
			if let Some(n) = parse_stream_name(&data.c_stream_name[..len]) {
				out.extend_from_slice(&utf16_to_wtf8(n));
				out.push(0);
			}
			// SAFETY: open find handle, valid out-pointer.
			if unsafe { FindNextStreamW(find.0, &mut data) } == 0 {
				let e = unsafe { GetLastError() };
				if e == ERROR_HANDLE_EOF {
					break;
				}
				return Err(map_win(e, Ctx::Path));
			}
		}
		Ok(out)
	}

	/// Named streams are bounded only by volume capacity.
	fn limits(&self, _path: &CStr) -> i64 {
		-1
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn parse_stream_name_extracts_named_data_streams_only() {
		let w = |s: &str| s.encode_utf16().collect::<Vec<u16>>();
		assert_eq!(parse_stream_name(&w(":k:$DATA")), Some(&w("k")[..]));
		assert_eq!(parse_stream_name(&w(":Zone.Identifier:$DATA")), Some(&w("Zone.Identifier")[..]));
		for bad in ["::$DATA", ":$I30:$INDEX_ALLOCATION", "", "junk"] {
			assert_eq!(parse_stream_name(&w(bad)), None, "{bad}");
		}
	}

	#[test]
	fn wtf8_and_utf16_convert_both_ways_including_lone_surrogates() {
		let cases: [&[u16]; 4] = [&[0x61, 0xE9, 0x20AC], &[0xD83D, 0xDE00], &[0xD800], &[0x61, 0xDC00, 0x62]];
		for units in cases {
			assert_eq!(wtf8_to_utf16(&utf16_to_wtf8(units)).as_deref(), Some(units));
		}
		for bad in [&b"\xff"[..], b"\xc3", b"\xc0\xaf", b"\xf4\x90\x80\x80", b"\xe2\x88"] {
			assert_eq!(wtf8_to_utf16(bad), None, "{bad:?}");
		}
	}
}
