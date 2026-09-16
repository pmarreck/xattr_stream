//! C ABI (FFI) surface for xattr_stream. This is the ONLY root that defines
//! `export fn xs_*`; the importable `xattr_stream` Zig module never emits C
//! symbols, so several static consumers can link without duplicate symbols.
//! Contract details live in include/xattr_stream.h; the two must agree.
const std = @import("std");
const builtin = @import("builtin");
const xs = @import("xattr_stream.zig");

/// Thread-safe, libc-free allocator for buffers handed to C callers.
const ffi_allocator = std.heap.smp_allocator;

pub const XS_OK: c_int = 0;
pub const XS_MISSING: c_int = 1;
pub const XS_UNSUPPORTED: c_int = 2;
pub const XS_READ_ONLY: c_int = 3;
pub const XS_PERMISSION: c_int = 4;
pub const XS_TOO_LARGE: c_int = 5;
pub const XS_NOT_FOUND: c_int = 6;
pub const XS_INVALID_NAME: c_int = 7;
pub const XS_INVALID_PATH: c_int = 8;
pub const XS_CHANGED: c_int = 9;
pub const XS_BUFFER_TOO_SMALL: c_int = 10;
pub const XS_OUT_OF_MEMORY: c_int = 11;
pub const XS_IO: c_int = 12;
pub const XS_INVALID_ARGUMENT: c_int = 13;

/// Mirrors XS_DEFAULT_MAX_VALUE_LEN in the header.
pub const XS_DEFAULT_MAX_VALUE_LEN: usize = xs.default_max_value_len;

/// Values up to this size fit every mainstream filesystem's default
/// configuration (ext4 without ea_inode holds about one 4 KiB block of
/// attributes per inode). Advisory; the CLI warns above it.
pub const XS_PORTABLE_VALUE_LEN: usize = 4096;

// Name rejection reasons, mirrored by `enum xs_name_rejection` in the header.
pub const XS_NAME_OK: c_int = 0;
pub const XS_NAME_EMPTY: c_int = 1;
pub const XS_NAME_TOO_LONG: c_int = 2;
pub const XS_NAME_CONTROL_CHAR: c_int = 3;
pub const XS_NAME_FORBIDDEN_CHAR: c_int = 4;
pub const XS_NAME_RESERVED: c_int = 5;
pub const XS_NAME_NOT_UTF8: c_int = 6;
pub const XS_NAME_EDGE_WHITESPACE_OR_DOT: c_int = 7;
pub const XS_NAME_LINUX_NAMESPACE: c_int = 8;
pub const XS_NAME_INVALID_NATIVE: c_int = 9;

fn rejectionCode(r: ?xs.names.Rejection) c_int {
	const rej = r orelse return XS_NAME_OK;
	return switch (rej) {
		.empty => XS_NAME_EMPTY,
		.too_long => XS_NAME_TOO_LONG,
		.control_char => XS_NAME_CONTROL_CHAR,
		.forbidden_char => XS_NAME_FORBIDDEN_CHAR,
		.reserved => XS_NAME_RESERVED,
		.not_utf8 => XS_NAME_NOT_UTF8,
		.edge_whitespace_or_dot => XS_NAME_EDGE_WHITESPACE_OR_DOT,
		.linux_namespace => XS_NAME_LINUX_NAMESPACE,
		.invalid_native => XS_NAME_INVALID_NATIVE,
	};
}

fn rejectionFromCode(code: c_int) ?xs.names.Rejection {
	return switch (code) {
		XS_NAME_EMPTY => .empty,
		XS_NAME_TOO_LONG => .too_long,
		XS_NAME_CONTROL_CHAR => .control_char,
		XS_NAME_FORBIDDEN_CHAR => .forbidden_char,
		XS_NAME_RESERVED => .reserved,
		XS_NAME_NOT_UTF8 => .not_utf8,
		XS_NAME_EDGE_WHITESPACE_OR_DOT => .edge_whitespace_or_dot,
		XS_NAME_LINUX_NAMESPACE => .linux_namespace,
		XS_NAME_INVALID_NATIVE => .invalid_native,
		else => null,
	};
}

pub const XS_FLAG_NOFOLLOW: u32 = 1 << 0;
pub const XS_FLAG_RAW_NAMES: u32 = 1 << 1;

pub const xs_options = extern struct {
	flags: u32,
	max_value_len: u64,
};

pub const xs_buffer = extern struct {
	data: ?[*]u8,
	len: usize,
	cap: usize,
};

const target_string = @tagName(builtin.cpu.arch) ++ "-" ++ @tagName(builtin.os.tag);

comptime {
	// The header's enum is frozen; keep the Zig side pinned to it.
	std.debug.assert(xs.statusCode(error.Missing) == XS_MISSING);
	std.debug.assert(xs.statusCode(error.Io) == XS_IO);
	std.debug.assert(@intFromEnum(xs.Status.invalid_argument) == XS_INVALID_ARGUMENT);
	std.debug.assert(XS_DEFAULT_MAX_VALUE_LEN == 65536);
}

fn optionsFrom(o: ?*const xs_options) xs.Options {
	const p = o orelse return .{};
	const max: usize = if (p.max_value_len == 0) xs.default_max_value_len else @intCast(@min(p.max_value_len, std.math.maxInt(usize)));
	return .{
		.follow_symlinks = (p.flags & XS_FLAG_NOFOLLOW) == 0,
		.raw_names = (p.flags & XS_FLAG_RAW_NAMES) != 0,
		.max_value_len = max,
	};
}

/// (ptr, len) to slice; NULL is legal only with len 0.
fn slice(ptr: ?[*]const u8, len: usize) ?[]const u8 {
	if (len == 0) return &.{};
	const p = ptr orelse return null;
	return p[0..len];
}

fn status(err: xs.Error) c_int {
	return xs.statusCode(err);
}

pub export fn xs_set(path: ?[*]const u8, path_len: usize, name: ?[*]const u8, name_len: usize, value: ?[*]const u8, value_len: usize, opts: ?*const xs_options) callconv(.c) c_int {
	const p = slice(path, path_len) orelse return XS_INVALID_PATH;
	const n = slice(name, name_len) orelse return XS_INVALID_NAME;
	const v = slice(value, value_len) orelse return XS_INVALID_ARGUMENT;
	xs.set(p, n, v, optionsFrom(opts)) catch |e| return status(e);
	return XS_OK;
}

pub export fn xs_size(path: ?[*]const u8, path_len: usize, name: ?[*]const u8, name_len: usize, opts: ?*const xs_options, out_len: ?*u64) callconv(.c) c_int {
	const o = out_len orelse return XS_INVALID_ARGUMENT;
	const p = slice(path, path_len) orelse return XS_INVALID_PATH;
	const n = slice(name, name_len) orelse return XS_INVALID_NAME;
	const sz = xs.size(p, n, optionsFrom(opts)) catch |e| return status(e);
	o.* = sz;
	return XS_OK;
}

pub export fn xs_get_into(path: ?[*]const u8, path_len: usize, name: ?[*]const u8, name_len: usize, buf: ?[*]u8, buf_cap: usize, opts: ?*const xs_options, out_len: ?*usize) callconv(.c) c_int {
	const o = out_len orelse return XS_INVALID_ARGUMENT;
	const p = slice(path, path_len) orelse return XS_INVALID_PATH;
	const n = slice(name, name_len) orelse return XS_INVALID_NAME;
	const dst: []u8 = if (buf_cap == 0) &.{} else (buf orelse return XS_INVALID_ARGUMENT)[0..buf_cap];
	const got = xs.getInto(p, n, dst, optionsFrom(opts)) catch |e| return status(e);
	o.* = got;
	return XS_OK;
}

pub export fn xs_get(path: ?[*]const u8, path_len: usize, name: ?[*]const u8, name_len: usize, opts: ?*const xs_options, out: ?*xs_buffer) callconv(.c) c_int {
	const o = out orelse return XS_INVALID_ARGUMENT;
	o.* = .{ .data = null, .len = 0, .cap = 0 };
	const p = slice(path, path_len) orelse return XS_INVALID_PATH;
	const n = slice(name, name_len) orelse return XS_INVALID_NAME;
	const v = xs.get(ffi_allocator, p, n, optionsFrom(opts)) catch |e| return status(e);
	o.* = .{ .data = if (v.len == 0) null else v.ptr, .len = v.len, .cap = v.len };
	return XS_OK;
}

pub export fn xs_remove(path: ?[*]const u8, path_len: usize, name: ?[*]const u8, name_len: usize, opts: ?*const xs_options) callconv(.c) c_int {
	const p = slice(path, path_len) orelse return XS_INVALID_PATH;
	const n = slice(name, name_len) orelse return XS_INVALID_NAME;
	xs.remove(p, n, optionsFrom(opts)) catch |e| return status(e);
	return XS_OK;
}

pub export fn xs_list(path: ?[*]const u8, path_len: usize, opts: ?*const xs_options, out: ?*xs_buffer, out_count: ?*usize) callconv(.c) c_int {
	const o = out orelse return XS_INVALID_ARGUMENT;
	const c = out_count orelse return XS_INVALID_ARGUMENT;
	o.* = .{ .data = null, .len = 0, .cap = 0 };
	c.* = 0;
	const p = slice(path, path_len) orelse return XS_INVALID_PATH;
	const l = xs.list(ffi_allocator, p, optionsFrom(opts)) catch |e| return status(e);
	o.* = .{ .data = if (l.bytes.len == 0) null else l.bytes.ptr, .len = l.bytes.len, .cap = l.bytes.len };
	c.* = l.count;
	return XS_OK;
}

pub export fn xs_buffer_free(buf: ?*xs_buffer) callconv(.c) void {
	const b = buf orelse return;
	if (b.data) |d| ffi_allocator.free(d[0..b.cap]);
	b.* = .{ .data = null, .len = 0, .cap = 0 };
}

pub export fn xs_limits(path: ?[*]const u8, path_len: usize) callconv(.c) i64 {
	const p = slice(path, path_len) orelse return -1;
	return xs.limits(p);
}

pub export fn xs_native_name(name: ?[*]const u8, name_len: usize, opts: ?*const xs_options, out: ?[*]u8, out_cap: usize, out_len: ?*usize) callconv(.c) c_int {
	const o = out_len orelse return XS_INVALID_ARGUMENT;
	const n = slice(name, name_len) orelse return XS_INVALID_NAME;
	var buf: [xs.names.native_buf_len]u8 = undefined;
	const native = xs.nativeName(n, optionsFrom(opts), &buf) catch |e| return status(e);
	o.* = native.len;
	if (out_cap < native.len + 1) return XS_BUFFER_TOO_SMALL;
	const dst = out orelse return XS_INVALID_ARGUMENT;
	@memcpy(dst[0..native.len], native);
	dst[native.len] = 0;
	return XS_OK;
}

/// Why a name would be rejected under `opts`, as an xs_name_rejection code
/// (XS_NAME_OK when acceptable). Pure; touches no file.
pub export fn xs_validate_name(name: ?[*]const u8, name_len: usize, opts: ?*const xs_options) callconv(.c) c_int {
	const n = slice(name, name_len) orelse return XS_NAME_INVALID_NATIVE;
	const o = optionsFrom(opts);
	return rejectionCode(xs.names.classify(xs.os, n, .{ .raw = o.raw_names }));
}

pub export fn xs_name_rejection_name(code: c_int) callconv(.c) [*:0]const u8 {
	return switch (code) {
		XS_NAME_OK => "XS_NAME_OK",
		XS_NAME_EMPTY => "XS_NAME_EMPTY",
		XS_NAME_TOO_LONG => "XS_NAME_TOO_LONG",
		XS_NAME_CONTROL_CHAR => "XS_NAME_CONTROL_CHAR",
		XS_NAME_FORBIDDEN_CHAR => "XS_NAME_FORBIDDEN_CHAR",
		XS_NAME_RESERVED => "XS_NAME_RESERVED",
		XS_NAME_NOT_UTF8 => "XS_NAME_NOT_UTF8",
		XS_NAME_EDGE_WHITESPACE_OR_DOT => "XS_NAME_EDGE_WHITESPACE_OR_DOT",
		XS_NAME_LINUX_NAMESPACE => "XS_NAME_LINUX_NAMESPACE",
		XS_NAME_INVALID_NATIVE => "XS_NAME_INVALID_NATIVE",
		else => "XS_NAME_UNKNOWN",
	};
}

pub export fn xs_name_rejection_message(code: c_int) callconv(.c) [*:0]const u8 {
	const r = rejectionFromCode(code) orelse return if (code == XS_NAME_OK) "name is acceptable" else "unknown name rejection code";
	return xs.names.rejectionMessage(r).ptr;
}

pub export fn xs_status_name(s: c_int) callconv(.c) [*:0]const u8 {
	return xs.statusName(s).ptr;
}

pub export fn xs_last_os_error() callconv(.c) i32 {
	return xs.lastOsError();
}

pub export fn xs_version() callconv(.c) [*:0]const u8 {
	return xs.version;
}

pub export fn xs_target() callconv(.c) [*:0]const u8 {
	return target_string;
}

test {
	_ = @import("ffi_test.zig");
}
