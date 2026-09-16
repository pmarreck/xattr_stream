//! xattr_stream core: binary-safe per-file byte attributes with one portable
//! name grammar and one error taxonomy across Linux (user.* xattrs), macOS
//! (xattrs) and Windows (NTFS alternate data streams).
//!
//! Hexagonal layout: this file is the port. `names.zig` is pure policy; the OS
//! adapters (`linux.zig`, `darwin.zig`, `windows.zig`) are selected at comptime
//! and expose the same five primitives. `getWith` is generic over the adapter
//! so the size-query/read race handling is testable with a fake adapter.
const std = @import("std");
const builtin = @import("builtin");
pub const names = @import("names.zig");

pub const version = "0.2.0";
pub const walk = @import("walk.zig");

/// Display heuristic for listings: a value is shown as text when it is valid
/// UTF-8 with no control characters other than TAB (so it fits on one line
/// unescaped); everything else, including multi-line text, is shown as hex.
/// `get` is unaffected and always emits raw bytes.
pub fn isDisplayText(bytes: []const u8) bool {
	for (bytes) |c| {
		if ((c < 0x20 and c != '\t') or c == 0x7f) return false;
	}
	return std.unicode.utf8ValidateSlice(bytes);
}

pub const os: names.Os = switch (builtin.os.tag) {
	.linux => .linux,
	.macos => .macos,
	.windows => .windows,
	else => @compileError("xattr_stream supports Linux, macOS and Windows only"),
};

const adapter = switch (builtin.os.tag) {
	.linux => @import("linux.zig"),
	.macos => @import("darwin.zig"),
	.windows => @import("windows.zig"),
	else => unreachable,
};

/// The stable error taxonomy. `Unsupported` means the filesystem or OS cannot
/// hold attributes at all; it is never evidence that a value was tampered with.
pub const Error = error{
	/// The attribute does not exist on an existing path.
	Missing,
	/// The filesystem or OS does not support attributes (ENOTSUP, FAT volumes).
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
	/// Caller buffer smaller than the current value (`getInto`).
	BufferTooSmall,
	OutOfMemory,
	/// Any other OS error; see `lastOsError`.
	Io,
};

/// C ABI status codes; the order is frozen and mirrored in include/xattr_stream.h.
pub const Status = enum(c_int) {
	ok = 0,
	missing = 1,
	unsupported = 2,
	read_only = 3,
	permission = 4,
	too_large = 5,
	not_found = 6,
	invalid_name = 7,
	invalid_path = 8,
	changed = 9,
	buffer_too_small = 10,
	out_of_memory = 11,
	io = 12,
	/// FFI-only: NULL pointer with nonzero length, or NULL out-parameter.
	invalid_argument = 13,
};

pub fn statusOf(err: ?Error) Status {
	const e = err orelse return .ok;
	return switch (e) {
		error.Missing => .missing,
		error.Unsupported => .unsupported,
		error.ReadOnly => .read_only,
		error.Permission => .permission,
		error.TooLarge => .too_large,
		error.NotFound => .not_found,
		error.InvalidName => .invalid_name,
		error.InvalidPath => .invalid_path,
		error.Changed => .changed,
		error.BufferTooSmall => .buffer_too_small,
		error.OutOfMemory => .out_of_memory,
		error.Io => .io,
	};
}

pub fn statusCode(err: ?Error) c_int {
	return @intFromEnum(statusOf(err));
}

pub fn statusName(code: c_int) [:0]const u8 {
	const s = std.enums.fromInt(Status, code) orelse return "XS_UNKNOWN";
	return switch (s) {
		.ok => "XS_OK",
		.missing => "XS_MISSING",
		.unsupported => "XS_UNSUPPORTED",
		.read_only => "XS_READ_ONLY",
		.permission => "XS_PERMISSION",
		.too_large => "XS_TOO_LARGE",
		.not_found => "XS_NOT_FOUND",
		.invalid_name => "XS_INVALID_NAME",
		.invalid_path => "XS_INVALID_PATH",
		.changed => "XS_CHANGED",
		.buffer_too_small => "XS_BUFFER_TOO_SMALL",
		.out_of_memory => "XS_OUT_OF_MEMORY",
		.io => "XS_IO",
		.invalid_argument => "XS_INVALID_ARGUMENT",
	};
}

/// Default bound on any single value the library will read or write: the
/// smallest OS ceiling across targets, Linux's XATTR_SIZE_MAX (64 KiB), so a
/// value accepted on one platform is accepted on all of them. macOS and NTFS
/// allow far more; callers who knowingly target only those may raise it.
pub const default_max_value_len: usize = 64 << 10;
/// Bounded retries when a value changes between size query and read.
pub const max_get_attempts: usize = 4;
/// First attempt at any read or listing goes into a stack buffer of this
/// size, so values and name lists that fit cost one syscall instead of a
/// size query plus a read. Matches XS_PORTABLE_VALUE_LEN.
pub const optimistic_read_len: usize = 4096;

pub const Options = struct {
	/// Operate on the symlink target (true) or the link itself (false).
	follow_symlinks: bool = true,
	/// Pass native names through instead of the portable logical grammar.
	raw_names: bool = false,
	/// Reject values larger than this on set, and before allocating on get.
	max_value_len: usize = default_max_value_len,
};

threadlocal var last_os_error_code: i32 = 0;

/// Raw OS error (errno or Win32 code) behind the most recent failure on this thread.
pub fn lastOsError() i32 {
	return last_os_error_code;
}

pub fn setLastOsError(code: i32) void {
	last_os_error_code = code;
}

// Windows paths are WTF-8 here and can reach 32767 UTF-16 units; POSIX paths
// are bounded by PATH_MAX (4096 on Linux, 1024 on macOS).
const path_buf_len = if (builtin.os.tag == .windows) 32767 * 3 + 1 else 4096 + 1;
const PathBuf = [path_buf_len]u8;
const NameBuf = [names.native_buf_len]u8;

fn pathZ(path: []const u8, buf: *PathBuf) Error![:0]const u8 {
	if (path.len == 0 or path.len >= buf.len) return error.InvalidPath;
	if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
	@memcpy(buf[0..path.len], path);
	buf[path.len] = 0;
	return buf[0..path.len :0];
}

/// Native (OS-level) spelling of a logical name on this OS, NUL-terminated
/// into `buf` (at least `names.native_buf_len` bytes).
pub fn nativeName(name: []const u8, opts: Options, buf: []u8) Error![:0]u8 {
	return names.toNative(os, name, .{ .raw = opts.raw_names }, buf) catch return error.InvalidName;
}

/// Create or atomically replace (POSIX) the attribute. On Windows the stream
/// is truncated then rewritten; see README for the atomicity caveat.
pub fn set(path: []const u8, name: []const u8, value: []const u8, opts: Options) Error!void {
	var nbuf: NameBuf = undefined;
	const n = try nativeName(name, opts, &nbuf);
	var pbuf: PathBuf = undefined;
	const p = try pathZ(path, &pbuf);
	if (value.len > opts.max_value_len) return error.TooLarge;
	return adapter.write(p, n, !opts.follow_symlinks, value);
}

/// Current value length in bytes; `error.Missing` when absent.
pub fn size(path: []const u8, name: []const u8, opts: Options) Error!usize {
	var nbuf: NameBuf = undefined;
	const n = try nativeName(name, opts, &nbuf);
	var pbuf: PathBuf = undefined;
	const p = try pathZ(path, &pbuf);
	return adapter.size(p, n, !opts.follow_symlinks);
}

/// Read into a caller buffer without allocating. Returns the byte count;
/// `error.BufferTooSmall` when the value does not fit.
pub fn getInto(path: []const u8, name: []const u8, buf: []u8, opts: Options) Error!usize {
	var nbuf: NameBuf = undefined;
	const n = try nativeName(name, opts, &nbuf);
	var pbuf: PathBuf = undefined;
	const p = try pathZ(path, &pbuf);
	const nofollow = !opts.follow_symlinks;
	if (buf.len == 0) {
		// A zero-length read is a size query on POSIX, so answer it explicitly.
		const s = try adapter.size(p, n, nofollow);
		return if (s == 0) 0 else error.BufferTooSmall;
	}
	return adapter.read(p, n, nofollow, buf);
}

/// Read the whole value into a new allocation. Caller frees with `allocator`.
pub fn get(allocator: std.mem.Allocator, path: []const u8, name: []const u8, opts: Options) Error![]u8 {
	var nbuf: NameBuf = undefined;
	const n = try nativeName(name, opts, &nbuf);
	var pbuf: PathBuf = undefined;
	const p = try pathZ(path, &pbuf);
	return getWith(adapter, allocator, p, n, !opts.follow_symlinks, opts.max_value_len);
}

/// Size-query-then-read with defined behavior under concurrent mutation:
/// a value that grew is retried up to `max_get_attempts` times, then reported
/// as `error.Changed`; a value that shrank is returned at its actual length.
/// Generic over the adapter so the race handling is unit-testable.
pub fn getWith(comptime Adapter: type, allocator: std.mem.Allocator, path: [*:0]const u8, name: [*:0]const u8, nofollow: bool, max_value_len: usize) Error![]u8 {
	// Optimistic path: most values are small, so read straight into a stack
	// buffer and only fall back to size-query-then-read when it overflows.
	var small: [optimistic_read_len]u8 = undefined;
	if (Adapter.read(path, name, nofollow, &small)) |got| {
		if (got > max_value_len) return error.TooLarge;
		const out = allocator.alloc(u8, got) catch return error.OutOfMemory;
		@memcpy(out, small[0..got]);
		return out;
	} else |e| switch (e) {
		error.BufferTooSmall => {},
		else => return e,
	}
	var attempt: usize = 0;
	while (attempt < max_get_attempts) : (attempt += 1) {
		const expected = try Adapter.size(path, name, nofollow);
		if (expected > max_value_len) return error.TooLarge;
		if (expected == 0) return allocator.alloc(u8, 0) catch return error.OutOfMemory;
		const buf = allocator.alloc(u8, expected) catch return error.OutOfMemory;
		const got = Adapter.read(path, name, nofollow, buf) catch |e| {
			allocator.free(buf);
			if (e == error.BufferTooSmall) continue;
			return e;
		};
		if (got == expected) return buf;
		if (allocator.resize(buf, got)) return buf[0..got];
		defer allocator.free(buf);
		const out = allocator.alloc(u8, got) catch return error.OutOfMemory;
		@memcpy(out, buf[0..got]);
		return out;
	}
	return error.Changed;
}

/// Delete the attribute; `error.Missing` when it was not there.
pub fn remove(path: []const u8, name: []const u8, opts: Options) Error!void {
	var nbuf: NameBuf = undefined;
	const n = try nativeName(name, opts, &nbuf);
	var pbuf: PathBuf = undefined;
	const p = try pathZ(path, &pbuf);
	return adapter.remove(p, n, !opts.follow_symlinks);
}

/// Attribute names as a packed, NUL-terminated sequence. `count` entries.
pub const NameList = struct {
	bytes: []u8,
	count: usize,

	pub fn deinit(self: *NameList, allocator: std.mem.Allocator) void {
		allocator.free(self.bytes);
		self.* = undefined;
	}

	pub fn iterator(self: *const NameList) Iterator {
		return .{ .bytes = self.bytes, .pos = 0 };
	}

	pub const Iterator = struct {
		bytes: []const u8,
		pos: usize,

		pub fn next(self: *Iterator) ?[]const u8 {
			if (self.pos >= self.bytes.len) return null;
			const end = std.mem.indexOfScalarPos(u8, self.bytes, self.pos, 0) orelse self.bytes.len;
			const s = self.bytes[self.pos..end];
			self.pos = end + 1;
			return s;
		}
	};
};

/// List attribute names, sorted bytewise. In logical mode only names the
/// logical layer can address are returned (see `names.fromNative`); raw mode
/// lists everything.
pub fn list(allocator: std.mem.Allocator, path: []const u8, opts: Options) Error!NameList {
	var pbuf: PathBuf = undefined;
	const p = try pathZ(path, &pbuf);
	const raw = try adapter.listRaw(allocator, p, !opts.follow_symlinks);
	defer allocator.free(raw);
	return packLogical(allocator, raw, os, opts);
}

fn bytesLess(_: void, a: []const u8, b: []const u8) bool {
	return std.mem.order(u8, a, b) == .lt;
}

/// Pure: turns a native NUL-separated listing into the logical, bytewise
/// sorted, NUL-terminated form. Filesystems return names in arbitrary order
/// (hash order on ZFS, insertion order on ext4, enumeration order on NTFS),
/// so sorting here is what makes listings identical across platforms.
pub fn packLogical(allocator: std.mem.Allocator, raw: []const u8, which: names.Os, opts: Options) Error!NameList {
	var items: std.ArrayList([]const u8) = .empty;
	defer items.deinit(allocator);
	var it = std.mem.splitScalar(u8, raw, 0);
	while (it.next()) |native| {
		if (native.len == 0) continue;
		const logical = names.fromNative(which, native, .{ .raw = opts.raw_names }) orelse continue;
		items.append(allocator, logical) catch return error.OutOfMemory;
	}
	std.mem.sort([]const u8, items.items, {}, bytesLess);

	var out: std.ArrayList(u8) = .empty;
	errdefer out.deinit(allocator);
	for (items.items) |logical| {
		out.appendSlice(allocator, logical) catch return error.OutOfMemory;
		out.append(allocator, 0) catch return error.OutOfMemory;
	}
	const bytes = out.toOwnedSlice(allocator) catch return error.OutOfMemory;
	return .{ .bytes = bytes, .count = items.items.len };
}

/// Best-effort maximum value size in bytes for the filesystem holding `path`,
/// or -1 when unknown or unbounded.
pub fn limits(path: []const u8) i64 {
	var pbuf: PathBuf = undefined;
	const p = pathZ(path, &pbuf) catch return -1;
	return adapter.limits(p);
}

test {
	_ = names;
	_ = walk;
	_ = @import("xattr_stream_test.zig");
}
