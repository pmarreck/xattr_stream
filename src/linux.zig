//! Linux adapter: raw xattr syscalls via std.os.linux (no libc dependency).
//! The kernel enforces XATTR_SIZE_MAX (64 KiB) per value in the VFS, so
//! `limits` is a constant. ENODATA doubles as ENOATTR on Linux.
const std = @import("std");
const linux = std.os.linux;
const core = @import("xattr_stream.zig");
const Error = core.Error;

const Ctx = enum { generic, read };

fn mapErrno(e: linux.E, ctx: Ctx) Error {
	core.setLastOsError(@intCast(@intFromEnum(e)));
	return switch (e) {
		.NODATA => error.Missing,
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

fn check(rc: usize, ctx: Ctx) Error!usize {
	const e = linux.errno(rc);
	if (e != .SUCCESS) return mapErrno(e, ctx);
	return rc;
}

pub fn size(path: [*:0]const u8, name: [*:0]const u8, nofollow: bool) Error!usize {
	var dummy: [1]u8 = undefined;
	const rc = if (nofollow) linux.lgetxattr(path, name, &dummy, 0) else linux.getxattr(path, name, &dummy, 0);
	return check(rc, .generic);
}

pub fn read(path: [*:0]const u8, name: [*:0]const u8, nofollow: bool, buf: []u8) Error!usize {
	const rc = if (nofollow) linux.lgetxattr(path, name, buf.ptr, buf.len) else linux.getxattr(path, name, buf.ptr, buf.len);
	return check(rc, .read);
}

pub fn write(path: [*:0]const u8, name: [*:0]const u8, nofollow: bool, value: []const u8) Error!void {
	const rc = if (nofollow) linux.lsetxattr(path, name, value.ptr, value.len, 0) else linux.setxattr(path, name, value.ptr, value.len, 0);
	_ = try check(rc, .generic);
}

pub fn remove(path: [*:0]const u8, name: [*:0]const u8, nofollow: bool) Error!void {
	const rc = if (nofollow) linux.lremovexattr(path, name) else linux.removexattr(path, name);
	_ = try check(rc, .generic);
}

/// Native names packed NUL-terminated, exactly as listxattr returns them.
/// Uses the same bounded size-then-read retry as values.
pub fn listRaw(allocator: std.mem.Allocator, path: [*:0]const u8, nofollow: bool) Error![]u8 {
	var attempt: usize = 0;
	while (attempt < core.max_get_attempts) : (attempt += 1) {
		var dummy: [1]u8 = undefined;
		const expected = try check(if (nofollow) linux.llistxattr(path, &dummy, 0) else linux.listxattr(path, &dummy, 0), .generic);
		const buf = allocator.alloc(u8, expected) catch return error.OutOfMemory;
		const rc = if (nofollow) linux.llistxattr(path, buf.ptr, buf.len) else linux.listxattr(path, buf.ptr, buf.len);
		const got = check(rc, .read) catch |e| {
			allocator.free(buf);
			if (e == error.BufferTooSmall) continue;
			return e;
		};
		if (got == expected) return buf;
		defer allocator.free(buf);
		return allocator.dupe(u8, buf[0..got]) catch return error.OutOfMemory;
	}
	return error.Changed;
}

/// XATTR_SIZE_MAX from <linux/limits.h>; enforced by the VFS for every filesystem.
pub fn limits(_: [*:0]const u8) i64 {
	return 65536;
}
