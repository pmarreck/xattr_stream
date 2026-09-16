//! Integration tests against the real OS attribute interface (tests-first).
//! Every test uses an isolated std.testing.tmpDir fixture under .zig-cache;
//! nothing touches a real user's files, settings, or home directory.
const std = @import("std");
const builtin = @import("builtin");
const xs = @import("xattr_stream.zig");
const io = std.testing.io;
const alloc = std.testing.allocator;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectEqualStrings = std.testing.expectEqualStrings;

const Fixture = struct {
	tmp: std.testing.TmpDir,
	base: [:0]u8,

	fn init() !Fixture {
		var tmp = std.testing.tmpDir(.{});
		errdefer tmp.cleanup();
		const base = try tmp.dir.realPathFileAlloc(io, ".", alloc);
		errdefer alloc.free(base);
		// A filesystem without attribute support cannot verify anything here;
		// skip loudly instead of reporting false failures.
		try tmp.dir.writeFile(io, .{ .sub_path = "probe", .data = "" });
		const probe = try std.fs.path.join(alloc, &.{ base, "probe" });
		defer alloc.free(probe);
		xs.set(probe, "probe", "x", .{}) catch |e| switch (e) {
			error.Unsupported => {
				std.debug.print("SKIP: {s} does not support attributes\n", .{base});
				return error.SkipZigTest;
			},
			else => return e,
		};
		return .{ .tmp = tmp, .base = base };
	}

	fn deinit(self: *Fixture) void {
		alloc.free(self.base);
		self.tmp.cleanup();
	}

	fn file(self: *Fixture, name: []const u8) ![]u8 {
		try self.tmp.dir.writeFile(io, .{ .sub_path = name, .data = "" });
		return std.fs.path.join(alloc, &.{ self.base, name });
	}

	fn dir(self: *Fixture, name: []const u8) ![]u8 {
		try self.tmp.dir.createDir(io, name, .default_dir);
		return std.fs.path.join(alloc, &.{ self.base, name });
	}

	fn path(self: *Fixture, name: []const u8) ![]u8 {
		return std.fs.path.join(alloc, &.{ self.base, name });
	}
};

fn allBytes() [256]u8 {
	var v: [256]u8 = undefined;
	for (&v, 0..) |*b, i| b.* = @intCast(i);
	return v;
}

test "round trip every byte value on a file, size and bytes exact" {
	var fx = try Fixture.init();
	defer fx.deinit();
	const f = try fx.file("f");
	defer alloc.free(f);
	const value = allBytes();

	try xs.set(f, "llc.mecha.probe", &value, .{});
	try expectEqual(@as(usize, 256), try xs.size(f, "llc.mecha.probe", .{}));
	const got = try xs.get(alloc, f, "llc.mecha.probe", .{});
	defer alloc.free(got);
	try expectEqualSlices(u8, &value, got);
}

test "empty value is present, not missing" {
	var fx = try Fixture.init();
	defer fx.deinit();
	const f = try fx.file("f");
	defer alloc.free(f);

	try xs.set(f, "empty", "", .{});
	try expectEqual(@as(usize, 0), try xs.size(f, "empty", .{}));
	const got = try xs.get(alloc, f, "empty", .{});
	defer alloc.free(got);
	try expectEqual(@as(usize, 0), got.len);
	var l = try xs.list(alloc, f, .{});
	defer l.deinit(alloc);
	try expectEqual(@as(usize, 1), l.count);
	var it = l.iterator();
	try expectEqualStrings("empty", it.next().?);
}

test "directories carry attributes too" {
	var fx = try Fixture.init();
	defer fx.deinit();
	const d = try fx.dir("d");
	defer alloc.free(d);

	try xs.set(d, "dir.attr", "a\x00b\n\xff", .{});
	const got = try xs.get(alloc, d, "dir.attr", .{});
	defer alloc.free(got);
	try expectEqualSlices(u8, "a\x00b\n\xff", got);
	try xs.remove(d, "dir.attr", .{});
	try expectError(error.Missing, xs.size(d, "dir.attr", .{}));
}

test "missing attribute is Missing for size, get, getInto and remove" {
	var fx = try Fixture.init();
	defer fx.deinit();
	const f = try fx.file("f");
	defer alloc.free(f);
	var buf: [8]u8 = undefined;

	try expectError(error.Missing, xs.size(f, "nope", .{}));
	try expectError(error.Missing, xs.get(alloc, f, "nope", .{}));
	try expectError(error.Missing, xs.getInto(f, "nope", &buf, .{}));
	try expectError(error.Missing, xs.remove(f, "nope", .{}));
}

test "overwrite replaces the whole value" {
	var fx = try Fixture.init();
	defer fx.deinit();
	const f = try fx.file("f");
	defer alloc.free(f);

	try xs.set(f, "k", "first-longer-value", .{});
	try xs.set(f, "k", "2nd", .{});
	try expectEqual(@as(usize, 3), try xs.size(f, "k", .{}));
	const got = try xs.get(alloc, f, "k", .{});
	defer alloc.free(got);
	try expectEqualStrings("2nd", got);
}

test "list returns exactly the logical names set, remove drops them" {
	var fx = try Fixture.init();
	defer fx.deinit();
	const f = try fx.file("f");
	defer alloc.free(f);
	const wanted = [_][]const u8{ "alpha", "beta.gamma", "ünï" };
	for (wanted) |n| try xs.set(f, n, n, .{});

	var l = try xs.list(alloc, f, .{});
	defer l.deinit(alloc);
	try expectEqual(wanted.len, l.count);
	// The OS returns names in filesystem-specific order; the core sorts them
	// bytewise so every platform lists identically.
	var it = l.iterator();
	for (wanted) |w| try expectEqualStrings(w, it.next().?);
	try expect(it.next() == null);

	try xs.remove(f, "beta.gamma", .{});
	var l2 = try xs.list(alloc, f, .{});
	defer l2.deinit(alloc);
	try expectEqual(@as(usize, 2), l2.count);
	var it2 = l2.iterator();
	while (it2.next()) |name| try expect(!std.mem.eql(u8, "beta.gamma", name));
}

test "invalid logical names are rejected by every operation before any OS call" {
	var fx = try Fixture.init();
	defer fx.deinit();
	// Deliberately nonexistent path: InvalidName must win over NotFound.
	const f = try fx.path("does-not-exist");
	defer alloc.free(f);
	var buf: [8]u8 = undefined;
	const bad = [_][]const u8{ "", "a:b", "..\\x", "user.foo", "$DATA", "Zone.Identifier", "com.apple.quarantine", "a\x00b", "trailing." };
	for (bad) |n| {
		try expectError(error.InvalidName, xs.set(f, n, "v", .{}));
		try expectError(error.InvalidName, xs.size(f, n, .{}));
		try expectError(error.InvalidName, xs.get(alloc, f, n, .{}));
		try expectError(error.InvalidName, xs.getInto(f, n, &buf, .{}));
		try expectError(error.InvalidName, xs.remove(f, n, .{}));
	}
}

test "nonexistent path is NotFound for every operation" {
	var fx = try Fixture.init();
	defer fx.deinit();
	const f = try fx.path("does-not-exist");
	defer alloc.free(f);
	var buf: [8]u8 = undefined;
	try expectError(error.NotFound, xs.set(f, "k", "v", .{}));
	try expectError(error.NotFound, xs.size(f, "k", .{}));
	try expectError(error.NotFound, xs.get(alloc, f, "k", .{}));
	try expectError(error.NotFound, xs.getInto(f, "k", &buf, .{}));
	try expectError(error.NotFound, xs.remove(f, "k", .{}));
	try expectError(error.NotFound, xs.list(alloc, f, .{}));
}

test "values above max_value_len are TooLarge on set and get, without unbounded allocation" {
	var fx = try Fixture.init();
	defer fx.deinit();
	const f = try fx.file("f");
	defer alloc.free(f);
	const value = "0123456789abcdef";
	try expectError(error.TooLarge, xs.set(f, "k", value, .{ .max_value_len = 15 }));
	try xs.set(f, "k", value, .{ .max_value_len = 16 });
	try expectError(error.TooLarge, xs.get(alloc, f, "k", .{ .max_value_len = 15 }));
	const got = try xs.get(alloc, f, "k", .{ .max_value_len = 16 });
	defer alloc.free(got);
	try expectEqualStrings(value, got);
}

test "default value bound is the smallest OS ceiling (Linux 64 KiB) on every OS" {
	// Peter, 2026-09-16: cap every OS at the minimum of the maxima so a value
	// that works on one platform works on all of them, no surprises.
	try expectEqual(@as(usize, 65536), xs.default_max_value_len);
	var fx = try Fixture.init();
	defer fx.deinit();
	const f = try fx.file("f");
	defer alloc.free(f);
	const big = try alloc.alloc(u8, 65537);
	defer alloc.free(big);
	@memset(big, 'x');
	try expectError(error.TooLarge, xs.set(f, "k", big, .{}));
	if (builtin.os.tag == .linux) try expectEqual(@as(i64, 65536), xs.limits(f));
}

test "getInto reports BufferTooSmall and fills an exact buffer" {
	var fx = try Fixture.init();
	defer fx.deinit();
	const f = try fx.file("f");
	defer alloc.free(f);
	try xs.set(f, "k", "hello", .{});
	var small: [4]u8 = undefined;
	try expectError(error.BufferTooSmall, xs.getInto(f, "k", &small, .{}));
	var exact: [5]u8 = undefined;
	try expectEqual(@as(usize, 5), try xs.getInto(f, "k", &exact, .{}));
	try expectEqualStrings("hello", &exact);
}

test "symlink policy: follow reaches the target, nofollow addresses the link" {
	var fx = try Fixture.init();
	defer fx.deinit();
	const f = try fx.file("target");
	defer alloc.free(f);
	try fx.tmp.dir.symLink(io, "target", "link", .{});
	const l = try fx.path("link");
	defer alloc.free(l);

	try xs.set(l, "k", "via-link", .{});
	try expectEqual(@as(usize, 8), try xs.size(f, "k", .{}));

	const nofollow = xs.Options{ .follow_symlinks = false };
	switch (builtin.os.tag) {
		// Kernel policy: user.* attributes are not permitted on symlinks.
		.linux => try expectError(error.Permission, xs.set(l, "k", "on-link", nofollow)),
		else => {
			try xs.set(l, "k", "on-link", nofollow);
			try expectEqual(@as(usize, 7), try xs.size(l, "k", nofollow));
			try expectEqual(@as(usize, 8), try xs.size(f, "k", .{}));
		},
	}
}

test "attributes survive rename but not replacement by a fresh file" {
	var fx = try Fixture.init();
	defer fx.deinit();
	const a = try fx.file("a");
	defer alloc.free(a);
	try xs.set(a, "k", "keep", .{});

	try std.Io.Dir.rename(fx.tmp.dir, "a", fx.tmp.dir, "b", io);
	const b = try fx.path("b");
	defer alloc.free(b);
	const got = try xs.get(alloc, b, "k", .{});
	defer alloc.free(got);
	try expectEqualStrings("keep", got);

	// Replacement: a new file renamed over "b" carries only its own attributes.
	const c = try fx.file("c");
	defer alloc.free(c);
	try std.Io.Dir.rename(fx.tmp.dir, "c", fx.tmp.dir, "b", io);
	try expectError(error.Missing, xs.size(b, "k", .{}));
}

test "raw names address the native name directly and list natively" {
	var fx = try Fixture.init();
	defer fx.deinit();
	const f = try fx.file("f");
	defer alloc.free(f);
	const raw = xs.Options{ .raw_names = true };
	var nbuf: [xs.names.native_buf_len]u8 = undefined;
	const native = try xs.nativeName("rawtest", .{}, &nbuf);

	try xs.set(f, "rawtest", "v", .{});
	try expectEqual(@as(usize, 1), try xs.size(f, native, raw));
	var l = try xs.list(alloc, f, raw);
	defer l.deinit(alloc);
	var found = false;
	var it = l.iterator();
	while (it.next()) |n| {
		if (std.mem.eql(u8, n, native)) found = true;
	}
	try expect(found);
	try xs.remove(f, native, raw);
	try expectError(error.Missing, xs.size(f, "rawtest", .{}));
}

test "concurrent writers and readers on one file never corrupt a value" {
	var fx = try Fixture.init();
	defer fx.deinit();
	const f = try fx.file("f");
	defer alloc.free(f);
	const Worker = struct {
		fn run(path: []const u8, id: usize, failures: *std.atomic.Value(usize)) void {
			var name_buf: [16]u8 = undefined;
			const name = std.fmt.bufPrint(&name_buf, "w{d}", .{id}) catch unreachable;
			var i: usize = 0;
			while (i < 200) : (i += 1) {
				var vbuf: [64]u8 = undefined;
				const v = std.fmt.bufPrint(&vbuf, "{d}:{d}", .{ id, i }) catch unreachable;
				xs.set(path, name, v, .{}) catch {
					_ = failures.fetchAdd(1, .monotonic);
					continue;
				};
				// The shared key is hammered by everyone; any read must return a
				// whole value some writer wrote, never a torn one.
				xs.set(path, "shared", v, .{}) catch {
					_ = failures.fetchAdd(1, .monotonic);
				};
				const got = xs.get(std.heap.page_allocator, path, "shared", .{}) catch {
					_ = failures.fetchAdd(1, .monotonic);
					continue;
				};
				defer std.heap.page_allocator.free(got);
				if (std.mem.indexOfScalar(u8, got, ':') == null) _ = failures.fetchAdd(1, .monotonic);
			}
		}
	};
	var failures = std.atomic.Value(usize).init(0);
	var threads: [8]std.Thread = undefined;
	for (&threads, 0..) |*t, id| t.* = try std.Thread.spawn(.{}, Worker.run, .{ f, id, &failures });
	for (threads) |t| t.join();
	try expectEqual(@as(usize, 0), failures.load(.monotonic));
	var l = try xs.list(alloc, f, .{});
	defer l.deinit(alloc);
	try expectEqual(@as(usize, 9), l.count);
}

/// Fake adapter: the value grows on every size query, so the size-then-read
/// race never settles. Exercises the bounded retry in the core.
const GrowingAdapter = struct {
	var reported: usize = 0;
	pub fn size(_: [*:0]const u8, _: [*:0]const u8, _: bool) xs.Error!usize {
		reported += 1;
		return reported;
	}
	pub fn read(_: [*:0]const u8, _: [*:0]const u8, _: bool, buf: []u8) xs.Error!usize {
		if (buf.len < reported + 1) return error.BufferTooSmall;
		return reported + 1;
	}
};

/// Fake adapter: the value shrinks between the size query and the read.
const ShrinkingAdapter = struct {
	pub fn size(_: [*:0]const u8, _: [*:0]const u8, _: bool) xs.Error!usize {
		return 10;
	}
	pub fn read(_: [*:0]const u8, _: [*:0]const u8, _: bool, buf: []u8) xs.Error!usize {
		@memcpy(buf[0..3], "abc");
		return 3;
	}
};

test "get: a value that keeps growing is reported as Changed after bounded retries" {
	GrowingAdapter.reported = 0;
	try expectError(error.Changed, xs.getWith(GrowingAdapter, alloc, "p", "n", false, 1 << 20));
	try expectEqual(xs.max_get_attempts, GrowingAdapter.reported);
}

test "get: a value that shrinks is returned at its actual length" {
	const got = try xs.getWith(ShrinkingAdapter, alloc, "p", "n", false, 1 << 20);
	defer alloc.free(got);
	try expectEqualStrings("abc", got);
}

test "status codes are stable and named" {
	try expectEqual(@as(c_int, 0), xs.statusCode(null));
	try expectEqual(@as(c_int, 1), xs.statusCode(error.Missing));
	try expectEqual(@as(c_int, 2), xs.statusCode(error.Unsupported));
	try expectEqualStrings("XS_UNSUPPORTED", xs.statusName(xs.statusCode(error.Unsupported)));
	try expectEqualStrings("XS_OK", xs.statusName(0));
	try expectEqualStrings("XS_UNKNOWN", xs.statusName(999));
}

test "packLogical: native listing is filtered to logical names and sorted bytewise" {
	// Filesystem order is arbitrary (ZFS hashes, ext4 insertion, NTFS enumeration);
	// the core must produce one order everywhere.
	const raw_linux = "user.zeta\x00user.alpha\x00security.selinux\x00user.mid\x00user.\x00trusted.x\x00";
	var l = try xs.packLogical(alloc, raw_linux, .linux, .{});
	defer l.deinit(alloc);
	try expectEqual(@as(usize, 3), l.count);
	try expectEqualSlices(u8, "alpha\x00mid\x00zeta\x00", l.bytes);

	var r = try xs.packLogical(alloc, raw_linux, .linux, .{ .raw_names = true });
	defer r.deinit(alloc);
	try expectEqual(@as(usize, 6), r.count);
	try expectEqualSlices(u8, "security.selinux\x00trusted.x\x00user.\x00user.alpha\x00user.mid\x00user.zeta\x00", r.bytes);

	var e = try xs.packLogical(alloc, "", .windows, .{});
	defer e.deinit(alloc);
	try expectEqual(@as(usize, 0), e.count);
}
