//! Traversal-order tests over a fake directory tree (tests-first). The walker
//! is generic over a lister so ordering, depth limits, symlink handling and
//! error reporting are exact and machine-independent.
const std = @import("std");
const walk = @import("walk.zig");
const alloc = std.testing.allocator;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

/// r/
///   b/ z
///   a/ y, x/ deep
///   f1
///   l -> (symlink; must never be descended into)
/// "r/b" refuses to be listed when `deny_b` is set.
const FakeTree = struct {
	var deny_b: bool = false;

	pub fn kindOf(path: []const u8) walk.Error!walk.Kind {
		if (std.mem.eql(u8, path, "r/l")) return .symlink;
		if (std.mem.eql(u8, path, "r") or std.mem.eql(u8, path, "r/a") or std.mem.eql(u8, path, "r/b") or std.mem.eql(u8, path, "r/a/x")) return .directory;
		if (std.mem.eql(u8, path, "missing")) return error.NotFound;
		return .other;
	}

	pub fn children(allocator: std.mem.Allocator, path: []const u8) walk.Error![]walk.Entry {
		const Raw = struct { name: []const u8, kind: walk.Kind };
		const raw: []const Raw = if (std.mem.eql(u8, path, "r"))
			&.{ .{ .name = "b", .kind = .directory }, .{ .name = "a", .kind = .directory }, .{ .name = "f1", .kind = .other }, .{ .name = "l", .kind = .symlink } }
		else if (std.mem.eql(u8, path, "r/a"))
			&.{ .{ .name = "y", .kind = .other }, .{ .name = "x", .kind = .directory } }
		else if (std.mem.eql(u8, path, "r/a/x"))
			&.{.{ .name = "deep", .kind = .other }}
		else if (std.mem.eql(u8, path, "r/b"))
			(if (deny_b) return error.Permission else &.{.{ .name = "z", .kind = .other }})
		else
			return error.Io; // listing anything else (e.g. the symlink) is a walker bug
		const out = allocator.alloc(walk.Entry, raw.len) catch return error.OutOfMemory;
		for (raw, 0..) |r, i| out[i] = .{ .name = allocator.dupe(u8, r.name) catch return error.OutOfMemory, .kind = r.kind };
		return out;
	}
};

const Recorder = struct {
	lines: std.ArrayList(u8) = .empty,
	stop_at: ?[]const u8 = null,

	fn visit(self: *Recorder, v: walk.Visit) bool {
		// The walker joins with the platform separator; normalize to '/' so the
		// expected strings below hold on Windows too.
		var norm: [64]u8 = undefined;
		@memcpy(norm[0..v.path.len], v.path);
		std.mem.replaceScalar(u8, norm[0..v.path.len], '\\', '/');
		const line = std.fmt.allocPrint(alloc, "{d} {s} {s}{s}\n", .{ v.depth, @tagName(v.kind), norm[0..v.path.len], if (v.status != .ok) " !" else "" }) catch unreachable;
		defer alloc.free(line);
		self.lines.appendSlice(alloc, line) catch unreachable;
		if (self.stop_at) |s| if (std.mem.eql(u8, s, v.path)) return false;
		return true;
	}

	fn deinit(self: *Recorder) void {
		self.lines.deinit(alloc);
	}
};

fn run(root: []const u8, opts: walk.Options, stop_at: ?[]const u8) ![]u8 {
	var rec = Recorder{ .stop_at = stop_at };
	defer rec.deinit();
	try walk.walk(FakeTree, alloc, root, opts, &rec, Recorder.visit);
	return alloc.dupe(u8, rec.lines.items);
}

test "breadth-first: each level in bytewise order, symlinks visited but never entered" {
	FakeTree.deny_b = false;
	const got = try run("r", .{}, null);
	defer alloc.free(got);
	try expectEqualStrings(
		\\0 directory r
		\\1 directory r/a
		\\1 directory r/b
		\\1 other r/f1
		\\1 symlink r/l
		\\2 directory r/a/x
		\\2 other r/a/y
		\\2 other r/b/z
		\\3 other r/a/x/deep
		\\
	, got);
}

test "depth-first: pre-order, children in bytewise order" {
	FakeTree.deny_b = false;
	const got = try run("r", .{ .order = .depth_first }, null);
	defer alloc.free(got);
	try expectEqualStrings(
		\\0 directory r
		\\1 directory r/a
		\\2 directory r/a/x
		\\3 other r/a/x/deep
		\\2 other r/a/y
		\\1 directory r/b
		\\2 other r/b/z
		\\1 other r/f1
		\\1 symlink r/l
		\\
	, got);
}

test "depth limit: 0 is the root alone, 1 adds immediate children" {
	FakeTree.deny_b = false;
	const d0 = try run("r", .{ .max_depth = 0 }, null);
	defer alloc.free(d0);
	try expectEqualStrings("0 directory r\n", d0);
	const d1 = try run("r", .{ .max_depth = 1 }, null);
	defer alloc.free(d1);
	try expectEqualStrings(
		\\0 directory r
		\\1 directory r/a
		\\1 directory r/b
		\\1 other r/f1
		\\1 symlink r/l
		\\
	, d1);
	const d1_dfs = try run("r", .{ .max_depth = 1, .order = .depth_first }, null);
	defer alloc.free(d1_dfs);
	try expectEqualStrings(d1, d1_dfs);
}

test "an unlistable directory is reported in place and the walk continues" {
	FakeTree.deny_b = true;
	defer FakeTree.deny_b = false;
	const got = try run("r", .{}, null);
	defer alloc.free(got);
	try expectEqualStrings(
		\\0 directory r
		\\1 directory r/a
		\\1 directory r/b
		\\1 directory r/b !
		\\1 other r/f1
		\\1 symlink r/l
		\\2 directory r/a/x
		\\2 other r/a/y
		\\3 other r/a/x/deep
		\\
	, got);
}

test "the visitor can stop the walk; a non-directory root is visited alone; a missing root fails" {
	FakeTree.deny_b = false;
	const got = try run("r", .{ .order = .depth_first }, "r/a/x");
	defer alloc.free(got);
	try expectEqualStrings(
		\\0 directory r
		\\1 directory r/a
		\\2 directory r/a/x
		\\
	, got);
	const single = try run("r/f1", .{}, null);
	defer alloc.free(single);
	try expectEqualStrings("0 other r/f1\n", single);
	try std.testing.expectError(error.NotFound, run("missing", .{}, null));
}
