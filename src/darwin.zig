//! macOS adapter: libSystem xattr calls with the Darwin (position, options)
//! signature. XATTR_NOFOLLOW selects the symlink itself. ENOATTR is distinct
//! from ENODATA here. Cross-compiled from Linux; runtime-verified only when a
//! Mac runs the suite (see README "Platform verification").
const std = @import("std");
const c = std.c;
const core = @import("xattr_stream.zig");
const Error = core.Error;

extern "c" fn getxattr(path: [*:0]const u8, name: [*:0]const u8, value: ?[*]u8, size: usize, position: u32, options: c_int) isize;
extern "c" fn setxattr(path: [*:0]const u8, name: [*:0]const u8, value: [*]const u8, size: usize, position: u32, options: c_int) c_int;
extern "c" fn removexattr(path: [*:0]const u8, name: [*:0]const u8, options: c_int) c_int;
extern "c" fn listxattr(path: [*:0]const u8, namebuf: ?[*]u8, size: usize, options: c_int) isize;
extern "c" fn pathconf(path: [*:0]const u8, name: c_int) c_long;

const XATTR_NOFOLLOW: c_int = 0x0001;
/// <unistd.h>: _PC_XATTR_SIZE_BITS, number of bits in the maximum xattr size.
const PC_XATTR_SIZE_BITS: c_int = 26;

const Ctx = enum { generic, read };

fn mapErrno(e: c.E, ctx: Ctx) Error {
	core.setLastOsError(@intCast(@intFromEnum(e)));
	return switch (e) {
		.NOATTR => error.Missing,
		.OPNOTSUPP => error.Unsupported,
		.ROFS => error.ReadOnly,
		.ACCES, .PERM => error.Permission,
		.@"2BIG", .NOSPC, .DQUOT, .FBIG => error.TooLarge,
		.RANGE => if (ctx == .read) error.BufferTooSmall else error.TooLarge,
		.NOENT, .NOTDIR, .LOOP => error.NotFound,
		.NAMETOOLONG, .INVAL => error.InvalidName,
		.NOMEM => error.OutOfMemory,
		else => error.Io,
	};
}

fn errnoNow() c.E {
	return @enumFromInt(c._errno().*);
}

fn opts(nofollow: bool) c_int {
	return if (nofollow) XATTR_NOFOLLOW else 0;
}

pub fn size(path: [*:0]const u8, name: [*:0]const u8, nofollow: bool) Error!usize {
	const rc = getxattr(path, name, null, 0, 0, opts(nofollow));
	if (rc < 0) return mapErrno(errnoNow(), .generic);
	return @intCast(rc);
}

pub fn read(path: [*:0]const u8, name: [*:0]const u8, nofollow: bool, buf: []u8) Error!usize {
	const rc = getxattr(path, name, buf.ptr, buf.len, 0, opts(nofollow));
	if (rc < 0) return mapErrno(errnoNow(), .read);
	return @intCast(rc);
}

pub fn write(path: [*:0]const u8, name: [*:0]const u8, nofollow: bool, value: []const u8) Error!void {
	if (setxattr(path, name, value.ptr, value.len, 0, opts(nofollow)) != 0) return mapErrno(errnoNow(), .generic);
}

pub fn remove(path: [*:0]const u8, name: [*:0]const u8, nofollow: bool) Error!void {
	if (removexattr(path, name, opts(nofollow)) != 0) return mapErrno(errnoNow(), .generic);
}

pub fn listRaw(allocator: std.mem.Allocator, path: [*:0]const u8, nofollow: bool) Error![]u8 {
	// One syscall for the common case; the size-query loop below only runs
	// when the list overflows the stack buffer (ERANGE).
	var small: [core.optimistic_read_len]u8 = undefined;
	const first = listxattr(path, &small, small.len, opts(nofollow));
	if (first >= 0) {
		return allocator.dupe(u8, small[0..@intCast(first)]) catch return error.OutOfMemory;
	}
	const first_err = errnoNow();
	if (first_err != .RANGE) return mapErrno(first_err, .generic);
	var attempt: usize = 0;
	while (attempt < core.max_get_attempts) : (attempt += 1) {
		const q = listxattr(path, null, 0, opts(nofollow));
		if (q < 0) return mapErrno(errnoNow(), .generic);
		const expected: usize = @intCast(q);
		const buf = allocator.alloc(u8, expected) catch return error.OutOfMemory;
		const rc = listxattr(path, buf.ptr, buf.len, opts(nofollow));
		if (rc < 0) {
			allocator.free(buf);
			const e = errnoNow();
			if (e == .RANGE) continue;
			return mapErrno(e, .read);
		}
		const got: usize = @intCast(rc);
		if (got == expected) return buf;
		defer allocator.free(buf);
		return allocator.dupe(u8, buf[0..got]) catch return error.OutOfMemory;
	}
	return error.Changed;
}

/// pathconf(_PC_XATTR_SIZE_BITS) gives the bit width of the maximum value
/// size on the volume; -1 when the volume does not report it.
pub fn limits(path: [*:0]const u8) i64 {
	const bits = pathconf(path, PC_XATTR_SIZE_BITS);
	if (bits <= 0 or bits >= 63) return -1;
	return (@as(i64, 1) << @intCast(bits)) - 1;
}
