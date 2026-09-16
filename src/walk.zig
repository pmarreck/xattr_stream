//! Directory traversal for recursive listing: breadth-first (default) or
//! depth-first pre-order, bytewise-sorted children, optional depth limit.
//! Symlinks are visited but never entered, so link loops cannot recurse.
//! Generic over a lister type so ordering is unit-tested on a fake tree;
//! `FsLister` is the real one, built on std.Io.Dir so every target shares it.
const std = @import("std");
const builtin = @import("builtin");
const core = @import("xattr_stream.zig");

pub const Error = core.Error;

pub const Kind = enum(u8) { other = 0, directory = 1, symlink = 2 };
pub const Order = enum(u8) { breadth_first = 0, depth_first = 1 };

pub const Entry = struct {
	name: []const u8,
	kind: Kind,
};

pub const Options = struct {
	order: Order = .breadth_first,
	/// 0 visits the root alone; null is unlimited.
	max_depth: ?usize = null,
};

/// One callback per visited path. A directory that cannot be listed produces
/// a second visit for the same path with a non-ok `status`, then the walk
/// goes on with its siblings.
pub const Visit = struct {
	path: []const u8,
	kind: Kind,
	depth: usize,
	status: core.Status = .ok,
};

const Node = struct {
	path: []u8,
	kind: Kind,
	depth: usize,
};

fn entryLess(_: void, a: Entry, b: Entry) bool {
	return std.mem.order(u8, a.name, b.name) == .lt;
}

pub fn freeEntries(allocator: std.mem.Allocator, entries: []Entry) void {
	for (entries) |e| allocator.free(e.name);
	allocator.free(entries);
}

/// Walk `root`, calling `visit(ctx, v)` for each path; return false from the
/// visitor to stop. `Lister` provides `kindOf(path) Error!Kind` and
/// `children(allocator, path) Error![]Entry` (names allocated with `allocator`).
pub fn walk(comptime Lister: type, allocator: std.mem.Allocator, root: []const u8, opts: Options, ctx: anytype, comptime visit: fn (@TypeOf(ctx), Visit) bool) Error!void {
	const root_kind = try Lister.kindOf(root);
	var pending: std.ArrayList(Node) = .empty;
	defer {
		for (pending.items) |n| allocator.free(n.path);
		pending.deinit(allocator);
	}
	pending.append(allocator, .{ .path = allocator.dupe(u8, root) catch return error.OutOfMemory, .kind = root_kind, .depth = 0 }) catch return error.OutOfMemory;
	var head: usize = 0;

	while (true) {
		const node: Node = switch (opts.order) {
			.breadth_first => blk: {
				if (head >= pending.items.len) return;
				const n = pending.items[head];
				head += 1;
				break :blk n;
			},
			.depth_first => pending.pop() orelse return,
		};
		// Breadth-first keeps consumed nodes in the list (freed by the defer);
		// depth-first owns each popped node until the end of this iteration.
		defer if (opts.order == .depth_first) allocator.free(node.path);

		if (!visit(ctx, .{ .path = node.path, .kind = node.kind, .depth = node.depth })) return;
		if (node.kind != .directory) continue;
		if (opts.max_depth) |m| if (node.depth >= m) continue;

		const kids = Lister.children(allocator, node.path) catch |e| {
			if (!visit(ctx, .{ .path = node.path, .kind = node.kind, .depth = node.depth, .status = core.statusOf(e) })) return;
			continue;
		};
		defer freeEntries(allocator, kids);
		std.mem.sort(Entry, kids, {}, entryLess);

		var i: usize = 0;
		while (i < kids.len) : (i += 1) {
			// Depth-first pops from the back, so push in reverse to pop ascending.
			const k = if (opts.order == .depth_first) kids[kids.len - 1 - i] else kids[i];
			const child_path = std.fs.path.join(allocator, &.{ node.path, k.name }) catch return error.OutOfMemory;
			pending.append(allocator, .{ .path = child_path, .kind = k.kind, .depth = node.depth + 1 }) catch {
				allocator.free(child_path);
				return error.OutOfMemory;
			};
		}
	}
}

// ---------------------------------------------------------------------------
// Real filesystem lister over std.Io.Dir.

var io_state: std.atomic.Value(u8) = std.atomic.Value(u8).init(0);
var threaded: std.Io.Threaded = undefined;

/// Lazily built process-wide Io for the library's own directory reads. Never
/// deinitialized; it owns no threads until async work is requested, which
/// this module never does.
fn libIo() std.Io {
	if (io_state.load(.acquire) != 2) {
		if (io_state.cmpxchgStrong(0, 1, .acquire, .acquire) == null) {
			threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
			io_state.store(2, .release);
		} else {
			while (io_state.load(.acquire) != 2) std.atomic.spinLoopHint();
		}
	}
	return threaded.io();
}

fn mapIoError(e: anyerror) Error {
	return switch (e) {
		error.FileNotFound, error.NotDir => error.NotFound,
		error.AccessDenied, error.PermissionDenied => error.Permission,
		error.OutOfMemory => error.OutOfMemory,
		error.NameTooLong, error.BadPathName => error.InvalidPath,
		else => error.Io,
	};
}

fn kindFromFile(k: std.Io.File.Kind) Kind {
	return switch (k) {
		.directory => .directory,
		.sym_link => .symlink,
		else => .other,
	};
}

pub const FsLister = struct {
	pub fn kindOf(path: []const u8) Error!Kind {
		const st = std.Io.Dir.cwd().statFile(libIo(), path, .{ .follow_symlinks = false }) catch |e| return mapIoError(e);
		return kindFromFile(st.kind);
	}

	pub fn children(allocator: std.mem.Allocator, path: []const u8) Error![]Entry {
		const io = libIo();
		var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true, .follow_symlinks = false }) catch |e| return mapIoError(e);
		defer dir.close(io);
		var out: std.ArrayList(Entry) = .empty;
		errdefer freeEntries(allocator, out.items);
		var it = dir.iterate();
		while (it.next(io) catch |e| return mapIoError(e)) |entry| {
			const name = allocator.dupe(u8, entry.name) catch return error.OutOfMemory;
			out.append(allocator, .{ .name = name, .kind = kindFromFile(entry.kind) }) catch {
				allocator.free(name);
				return error.OutOfMemory;
			};
		}
		return out.toOwnedSlice(allocator) catch return error.OutOfMemory;
	}
};

test {
	_ = @import("walk_test.zig");
}
