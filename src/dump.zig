//! The per-file JSON dump format that `dump --json` writes and `load` reads:
//! one object per line, {"path"|"path_pb": str, "xattrs"?: {name: pb},
//! "xattrs_pb"?: {pb-name: pb}}. Pure: parses and classifies bytes, performs
//! no I/O and no printable-binary decoding (callers own both).
const std = @import("std");

pub const Field = enum(c_int) { path = 0, path_pb = 1, xattr = 2, xattr_pb = 3 };

pub const ParseError = error{ Malformed, OutOfMemory };

/// Restore-safety classifier: true when `path` is relative and never climbs
/// above its starting directory. Applies the union of POSIX and Windows rules
/// on every OS (a dump can move between systems): rejects empty paths, NUL,
/// a leading / or \ (root, UNC), a drive prefix like `C:`, and any `..`
/// component split on either separator.
// complexity: O(n)
pub fn isContainedRelativePath(path: []const u8) bool {
	if (path.len == 0) return false;
	if (std.mem.indexOfScalar(u8, path, 0) != null) return false;
	if (isAbsolutePath(path)) return false;
	var it = std.mem.tokenizeAny(u8, path, "/\\");
	while (it.next()) |component| {
		if (std.mem.eql(u8, component, "..")) return false;
	}
	return true;
}

/// True for a path anchored outside the current directory under POSIX or
/// Windows rules: a leading / or \ (root, UNC) or a drive prefix like `C:`.
/// Both rule sets apply on every OS, as in isContainedRelativePath.
pub fn isAbsolutePath(path: []const u8) bool {
	if (path.len == 0) return false;
	if (path[0] == '/' or path[0] == '\\') return true;
	return path.len >= 2 and path[1] == ':' and std.ascii.isAlphabetic(path[0]);
}

/// Parses one dump line and calls `emit(ctx, field, key, value)` for the path
/// (key empty) and then each attribute, `xattrs` before `xattrs_pb`, in
/// document order; `emit` returns false to stop. Strict: exactly one of
/// path/path_pb, string values only, no unknown or duplicate keys. Strings
/// are JSON-unescaped but otherwise passed through (still printable-binary
/// where the format says so). Parses with std.json into an arena.
pub fn parseLine(gpa: std.mem.Allocator, line: []const u8, ctx: anytype, comptime emit: fn (@TypeOf(ctx), Field, []const u8, []const u8) bool) ParseError!void {
	var arena = std.heap.ArenaAllocator.init(gpa);
	defer arena.deinit();
	const root = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), line, .{}) catch |e| switch (e) {
		error.OutOfMemory => return error.OutOfMemory,
		else => return error.Malformed,
	};
	const obj = switch (root) {
		.object => |o| o,
		else => return error.Malformed,
	};
	var path: ?[]const u8 = null;
	var path_field: Field = .path;
	var xattrs: ?std.json.ObjectMap = null;
	var xattrs_pb: ?std.json.ObjectMap = null;
	var it = obj.iterator();
	while (it.next()) |kv| {
		const key = kv.key_ptr.*;
		const val = kv.value_ptr.*;
		if (std.mem.eql(u8, key, "path") or std.mem.eql(u8, key, "path_pb")) {
			if (path != null) return error.Malformed;
			path = switch (val) {
				.string => |s| s,
				else => return error.Malformed,
			};
			path_field = if (key.len == 4) .path else .path_pb;
		} else if (std.mem.eql(u8, key, "xattrs")) {
			xattrs = try stringMap(val);
		} else if (std.mem.eql(u8, key, "xattrs_pb")) {
			xattrs_pb = try stringMap(val);
		} else {
			return error.Malformed;
		}
	}
	const p = path orelse return error.Malformed;
	if (!emit(ctx, path_field, "", p)) return;
	inline for (.{ .{ xattrs, Field.xattr }, .{ xattrs_pb, Field.xattr_pb } }) |pair| {
		if (pair[0]) |m| {
			var mit = m.iterator();
			while (mit.next()) |kv| {
				if (!emit(ctx, pair[1], kv.key_ptr.*, kv.value_ptr.string)) return;
			}
		}
	}
}

/// Validates an object whose values are all strings.
fn stringMap(val: std.json.Value) ParseError!std.json.ObjectMap {
	const m = switch (val) {
		.object => |o| o,
		else => return error.Malformed,
	};
	for (m.values()) |v| {
		if (v != .string) return error.Malformed;
	}
	return m;
}

test "isContainedRelativePath accepts relative paths and rejects absolute ones and backtracking, on every OS" {
	// The union of POSIX and Windows rules applies everywhere, because a dump
	// written on one OS can be loaded on another.
	const accept = [_][]const u8{ "a", "a/b", "./a", "a/./b", ".", "dir with space/f", "..a", "a..", "a/..b", "b/c..", "caf\xe9", "a/b/" };
	const reject = [_][]const u8{ "", "/a", "/", "//srv/x", "\\a", "\\\\srv\\share\\f", "C:/a", "c:a", "Z:\\x", "a/../b", "..", "../a", "a/..", "a\\..\\b", "..\\a", "a\x00b" };
	var accepted: usize = 0;
	for (accept) |p| accepted += @intFromBool(isContainedRelativePath(p));
	try std.testing.expectEqual(accept.len, accepted);
	var rejected: usize = 0;
	for (reject) |p| rejected += @intFromBool(!isContainedRelativePath(p));
	try std.testing.expectEqual(reject.len, rejected);
}

test "isAbsolutePath classifies POSIX roots, Windows roots, UNC and drive prefixes on every OS" {
	const accept = [_][]const u8{ "/", "/a", "//srv/x", "\\a", "\\\\srv\\share\\f", "C:/a", "c:a", "Z:\\x", "C:", "a:/b" };
	const reject = [_][]const u8{ "", "a", "./a", "../a", "a/b", "1:a", "ab:c", ":a" };
	var accepted: usize = 0;
	for (accept) |p| accepted += @intFromBool(isAbsolutePath(p));
	try std.testing.expectEqual(accept.len, accepted);
	var rejected: usize = 0;
	for (reject) |p| rejected += @intFromBool(!isAbsolutePath(p));
	try std.testing.expectEqual(reject.len, rejected);
}

const Recorder = struct {

	lines: std.ArrayList(u8) = .empty,
	stop_after: ?usize = null,
	seen: usize = 0,

	fn emit(self: *Recorder, field: Field, key: []const u8, value: []const u8) bool {
		const a = std.testing.allocator;
		const line = std.fmt.allocPrint(a, "{s}|{s}|{s}\n", .{ @tagName(field), key, value }) catch return false;
		defer a.free(line);
		self.lines.appendSlice(a, line) catch return false;
		self.seen += 1;
		return if (self.stop_after) |n| self.seen < n else true;
	}

	fn deinit(self: *Recorder) void {
		self.lines.deinit(std.testing.allocator);
	}
};

fn record(line: []const u8) ![]u8 {
	var r = Recorder{};
	defer r.deinit();
	try parseLine(std.testing.allocator, line, &r, Recorder.emit);
	return std.testing.allocator.dupe(u8, r.lines.items);
}

test "parseLine emits the path first, then xattrs and xattrs_pb entries in document order" {
	const a = std.testing.allocator;
	const cases = [_][2][]const u8{
		.{ "{\"xattrs\":{\"b\":\"2\",\"a\":\"1\"},\"path\":\"p\"}", "path||p\nxattr|b|2\nxattr|a|1\n" },
		.{ "{\"path_pb\":\"x\",\"xattrs_pb\":{\"n\":\"v\"},\"xattrs\":{\"k\":\"w\"}}", "path_pb||x\nxattr|k|w\nxattr_pb|n|v\n" },
		.{ "{\"path\":\"p\"}", "path||p\n" },
		.{ "  {\"path\":\"p\",\"xattrs\":{}}  ", "path||p\n" },
		.{ "{\"path\":\"a\\\"b\",\"xattrs\":{\"k\":\"\\u00e9 x\"}}", "path||a\"b\nxattr|k|\xc3\xa9 x\n" },
	};
	for (cases) |c| {
		const got = try record(c[0]);
		defer a.free(got);
		try std.testing.expectEqualStrings(c[1], got);
	}
}

test "parseLine rejects malformed lines as a set" {
	const reject = [_][]const u8{
		"",                                          "[]",
		"\"s\"",                                     "{}",
		"{\"xattrs\":{}}",                           "{\"path\":\"a\",\"path_pb\":\"b\"}",
		"{\"path\":1}",                              "{\"path\":null}",
		"{\"path\":\"a\",\"xattrs\":[]}",            "{\"path\":\"a\",\"xattrs\":{\"k\":1}}",
		"{\"path\":\"a\",\"extra\":1}",              "{\"path\":\"a\",\"path\":\"b\"}",
		"{\"path\":\"a\",\"xattrs\":{\"k\":\"1\",\"k\":\"2\"}}", "{\"path\":\"a\"} x",
		"{\"path\":\"a\"",                           "{\"path\":\"a\",\"xattrs_pb\":{\"k\":{}}}",
	};
	var rejected: usize = 0;
	for (reject) |line| {
		var r = Recorder{};
		defer r.deinit();
		if (parseLine(std.testing.allocator, line, &r, Recorder.emit)) |_| {
			std.debug.print("accepted malformed line: {s}\n", .{line});
		} else |e| {
			try std.testing.expectEqual(error.Malformed, e);
			try std.testing.expectEqual(@as(usize, 0), r.seen);
			rejected += 1;
		}
	}
	try std.testing.expectEqual(reject.len, rejected);
}

test "parseLine stops when the callback returns false" {
	var r = Recorder{ .stop_after = 2 };
	defer r.deinit();
	try parseLine(std.testing.allocator, "{\"path\":\"p\",\"xattrs\":{\"a\":\"1\",\"b\":\"2\",\"c\":\"3\"}}", &r, Recorder.emit);
	try std.testing.expectEqual(@as(usize, 2), r.seen);
}
