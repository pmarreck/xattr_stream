//! Windows adapter: NTFS alternate data streams (`path:name`), chosen over
//! NTFS extended attributes deliberately. Streams hold arbitrary sizes, are
//! visible to users (`dir /r`), survive copies between NTFS volumes, and are
//! the mechanism Windows itself uses for per-file metadata (Zone.Identifier).
//! EAs are capped at 64 KiB per file, invisible to most tools, and reserved
//! in practice for WSL/Cygwin POSIX metadata. Stream writes are not atomic
//! with respect to concurrent readers (truncate, then write); see README.
//!
//! Cross-compiled from Linux; runtime-verified only when a Windows machine
//! runs the suite (see README "Platform verification").
const std = @import("std");
const w = std.os.windows;
const core = @import("xattr_stream.zig");
const Error = core.Error;

const HANDLE = w.HANDLE;
const DWORD = w.DWORD;
const BOOL = c_int;
const LPCWSTR = w.LPCWSTR;

const WIN32_FIND_STREAM_DATA = extern struct {
	StreamSize: i64,
	cStreamName: [w.MAX_PATH + 36]u16,
};

extern "kernel32" fn CreateFileW(lpFileName: LPCWSTR, dwDesiredAccess: DWORD, dwShareMode: DWORD, lpSecurityAttributes: ?*anyopaque, dwCreationDisposition: DWORD, dwFlagsAndAttributes: DWORD, hTemplateFile: ?HANDLE) callconv(.winapi) HANDLE;
extern "kernel32" fn ReadFile(hFile: HANDLE, lpBuffer: [*]u8, nNumberOfBytesToRead: DWORD, lpNumberOfBytesRead: *DWORD, lpOverlapped: ?*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn WriteFile(hFile: HANDLE, lpBuffer: [*]const u8, nNumberOfBytesToWrite: DWORD, lpNumberOfBytesWritten: *DWORD, lpOverlapped: ?*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn DeleteFileW(lpFileName: LPCWSTR) callconv(.winapi) BOOL;
extern "kernel32" fn GetFileSizeEx(hFile: HANDLE, lpFileSize: *i64) callconv(.winapi) BOOL;
extern "kernel32" fn GetFileAttributesW(lpFileName: LPCWSTR) callconv(.winapi) DWORD;
extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;
extern "kernel32" fn FindFirstStreamW(lpFileName: LPCWSTR, InfoLevel: c_int, lpFindStreamData: *WIN32_FIND_STREAM_DATA, dwFlags: DWORD) callconv(.winapi) HANDLE;
extern "kernel32" fn FindNextStreamW(hFindStream: HANDLE, lpFindStreamData: *WIN32_FIND_STREAM_DATA) callconv(.winapi) BOOL;
extern "kernel32" fn FindClose(hFindFile: HANDLE) callconv(.winapi) BOOL;

const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(std.math.maxInt(usize));
const INVALID_FILE_ATTRIBUTES: DWORD = 0xFFFFFFFF;
const GENERIC_READ: DWORD = 0x80000000;
const GENERIC_WRITE: DWORD = 0x40000000;
const FILE_READ_ATTRIBUTES: DWORD = 0x0080;
const FILE_SHARE_ALL: DWORD = 0x1 | 0x2 | 0x4;
const CREATE_ALWAYS: DWORD = 2;
const OPEN_EXISTING: DWORD = 3;
const FILE_ATTRIBUTE_NORMAL: DWORD = 0x80;
const FILE_FLAG_BACKUP_SEMANTICS: DWORD = 0x02000000;
const FILE_FLAG_OPEN_REPARSE_POINT: DWORD = 0x00200000;

const ERROR_INVALID_FUNCTION: DWORD = 1;
const ERROR_FILE_NOT_FOUND: DWORD = 2;
const ERROR_PATH_NOT_FOUND: DWORD = 3;
const ERROR_ACCESS_DENIED: DWORD = 5;
const ERROR_NOT_ENOUGH_MEMORY: DWORD = 8;
const ERROR_WRITE_PROTECT: DWORD = 19;
const ERROR_HANDLE_EOF: DWORD = 38;
const ERROR_HANDLE_DISK_FULL: DWORD = 39;
const ERROR_NOT_SUPPORTED: DWORD = 50;
const ERROR_DISK_FULL: DWORD = 112;
const ERROR_INVALID_NAME: DWORD = 123;
const ERROR_FILE_TOO_LARGE: DWORD = 223;
const ERROR_EAS_NOT_SUPPORTED: DWORD = 282;

/// Longest path the NT object manager accepts, in UTF-16 units.
const max_wpath = 32767;
const WPath = [max_wpath + 1]u16;

const Ctx = enum { path, attr, read };

/// Maps a Win32 error to the taxonomy. FILE/PATH_NOT_FOUND means the base
/// path is gone when `ctx == .path`, otherwise that the stream is absent.
/// INVALID_NAME after our own validation means the volume has no stream
/// support (FAT/exFAT), so it is reported as Unsupported.
fn mapWin(code: DWORD, ctx: Ctx) Error {
	core.setLastOsError(@bitCast(code));
	return switch (code) {
		ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND => if (ctx == .path) error.NotFound else error.Missing,
		ERROR_ACCESS_DENIED => error.Permission,
		ERROR_WRITE_PROTECT => error.ReadOnly,
		ERROR_HANDLE_DISK_FULL, ERROR_DISK_FULL, ERROR_FILE_TOO_LARGE => error.TooLarge,
		ERROR_INVALID_FUNCTION, ERROR_NOT_SUPPORTED, ERROR_INVALID_NAME, ERROR_EAS_NOT_SUPPORTED => error.Unsupported,
		ERROR_NOT_ENOUGH_MEMORY => error.OutOfMemory,
		else => error.Io,
	};
}

fn toWide(path: [*:0]const u8, out: *WPath) Error![:0]u16 {
	const n = std.unicode.wtf8ToWtf16Le(out[0..max_wpath], std.mem.span(path)) catch return error.InvalidPath;
	out[n] = 0;
	return out[0..n :0];
}

/// `path:name` in UTF-16. The name was validated to exclude `:` `\` `/`, so
/// the only path separator introduced here is the one stream delimiter.
fn streamPath(path: [*:0]const u8, name: [*:0]const u8, out: *WPath) Error![:0]u16 {
	var n = std.unicode.wtf8ToWtf16Le(out[0..max_wpath], std.mem.span(path)) catch return error.InvalidPath;
	if (n + 1 >= max_wpath) return error.InvalidPath;
	out[n] = ':';
	n += 1;
	const m = std.unicode.wtf8ToWtf16Le(out[n..max_wpath], std.mem.span(name)) catch return error.InvalidName;
	n += m;
	out[n] = 0;
	return out[0..n :0];
}

/// The base file or directory must already exist: CREATE_ALWAYS on a stream
/// would otherwise create the file, and a missing stream would be
/// indistinguishable from a missing path.
fn requireBase(path: [*:0]const u8) Error!void {
	var wbuf: WPath = undefined;
	const wp = try toWide(path, &wbuf);
	if (GetFileAttributesW(wp.ptr) == INVALID_FILE_ATTRIBUTES) return mapWin(GetLastError(), .path);
}

fn openStream(path: [*:0]const u8, name: [*:0]const u8, nofollow: bool, access: DWORD, disposition: DWORD) Error!HANDLE {
	try requireBase(path);
	var wbuf: WPath = undefined;
	const ws = try streamPath(path, name, &wbuf);
	var flags: DWORD = FILE_ATTRIBUTE_NORMAL | FILE_FLAG_BACKUP_SEMANTICS;
	if (nofollow) flags |= FILE_FLAG_OPEN_REPARSE_POINT;
	const h = CreateFileW(ws.ptr, access, FILE_SHARE_ALL, null, disposition, flags, null);
	if (h == INVALID_HANDLE_VALUE) return mapWin(GetLastError(), .attr);
	return h;
}

fn handleSize(h: HANDLE) Error!usize {
	var sz: i64 = 0;
	if (GetFileSizeEx(h, &sz) == 0) return mapWin(GetLastError(), .attr);
	return @intCast(sz);
}

pub fn size(path: [*:0]const u8, name: [*:0]const u8, nofollow: bool) Error!usize {
	const h = try openStream(path, name, nofollow, FILE_READ_ATTRIBUTES, OPEN_EXISTING);
	defer _ = CloseHandle(h);
	return handleSize(h);
}

pub fn read(path: [*:0]const u8, name: [*:0]const u8, nofollow: bool, buf: []u8) Error!usize {
	const h = try openStream(path, name, nofollow, GENERIC_READ, OPEN_EXISTING);
	defer _ = CloseHandle(h);
	const expected = try handleSize(h);
	if (expected > buf.len) return error.BufferTooSmall;
	var total: usize = 0;
	while (total < expected) {
		const chunk: DWORD = @intCast(@min(expected - total, std.math.maxInt(DWORD)));
		var got: DWORD = 0;
		if (ReadFile(h, buf.ptr + total, chunk, &got, null) == 0) return mapWin(GetLastError(), .read);
		if (got == 0) break;
		total += got;
	}
	return total;
}

pub fn write(path: [*:0]const u8, name: [*:0]const u8, nofollow: bool, value: []const u8) Error!void {
	const h = try openStream(path, name, nofollow, GENERIC_WRITE, CREATE_ALWAYS);
	defer _ = CloseHandle(h);
	var total: usize = 0;
	while (total < value.len) {
		const chunk: DWORD = @intCast(@min(value.len - total, std.math.maxInt(DWORD)));
		var written: DWORD = 0;
		if (WriteFile(h, value.ptr + total, chunk, &written, null) == 0) return mapWin(GetLastError(), .attr);
		if (written == 0) return mapWin(ERROR_DISK_FULL, .attr);
		total += written;
	}
}

pub fn remove(path: [*:0]const u8, name: [*:0]const u8, nofollow: bool) Error!void {
	_ = nofollow; // DeleteFileW never follows reparse points.
	try requireBase(path);
	var wbuf: WPath = undefined;
	const ws = try streamPath(path, name, &wbuf);
	if (DeleteFileW(ws.ptr) == 0) return mapWin(GetLastError(), .attr);
}

/// `:name:$DATA` -> `name`; the unnamed data stream (`::$DATA`) and
/// non-data stream types are skipped.
fn parseStreamName(wname: []const u16) ?[]const u16 {
	if (wname.len == 0 or wname[0] != ':') return null;
	const rest = wname[1..];
	const end = std.mem.indexOfScalar(u16, rest, ':') orelse rest.len;
	if (end == 0) return null;
	const data_suffix = std.unicode.wtf8ToWtf16LeStringLiteral(":$DATA");
	if (!std.mem.eql(u16, rest[end..], data_suffix)) return null;
	return rest[0..end];
}

test "parseStreamName extracts named $DATA streams only" {
	const L = std.unicode.wtf8ToWtf16LeStringLiteral;
	try std.testing.expectEqualSlices(u16, L("k"), parseStreamName(L(":k:$DATA")).?);
	try std.testing.expectEqualSlices(u16, L("Zone.Identifier"), parseStreamName(L(":Zone.Identifier:$DATA")).?);
	try std.testing.expect(parseStreamName(L("::$DATA")) == null);
	try std.testing.expect(parseStreamName(L(":$I30:$INDEX_ALLOCATION")) == null);
	try std.testing.expect(parseStreamName(L("")) == null);
	try std.testing.expect(parseStreamName(L("junk")) == null);
}

pub fn listRaw(allocator: std.mem.Allocator, path: [*:0]const u8, nofollow: bool) Error![]u8 {
	_ = nofollow; // FindFirstStreamW has no reparse-point flag; it enumerates the resolved path.
	try requireBase(path);
	var wbuf: WPath = undefined;
	const wp = try toWide(path, &wbuf);
	var data: WIN32_FIND_STREAM_DATA = undefined;
	const h = FindFirstStreamW(wp.ptr, 0, &data, 0);
	if (h == INVALID_HANDLE_VALUE) {
		const e = GetLastError();
		if (e == ERROR_HANDLE_EOF) return allocator.alloc(u8, 0) catch return error.OutOfMemory;
		return mapWin(e, .path);
	}
	defer _ = FindClose(h);

	var out: std.ArrayList(u8) = .empty;
	errdefer out.deinit(allocator);
	var name_buf: [(w.MAX_PATH + 36) * 3]u8 = undefined;
	while (true) {
		const wname = std.mem.sliceTo(&data.cStreamName, 0);
		if (parseStreamName(wname)) |n| {
			const len = std.unicode.wtf16LeToWtf8(&name_buf, n);
			out.appendSlice(allocator, name_buf[0..len]) catch return error.OutOfMemory;
			out.append(allocator, 0) catch return error.OutOfMemory;
		}
		if (FindNextStreamW(h, &data) == 0) {
			const e = GetLastError();
			if (e == ERROR_HANDLE_EOF) break;
			return mapWin(e, .path);
		}
	}
	return out.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

/// Named streams are bounded only by volume capacity.
pub fn limits(_: [*:0]const u8) i64 {
	return -1;
}
