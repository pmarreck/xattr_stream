const std = @import("std");
const xs = @import("xattr_stream");

test "Zig module consumer: round trip through the importable API" {
	const io = std.testing.io;
	const alloc = std.testing.allocator;
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();
	try tmp.dir.writeFile(io, .{ .sub_path = "f", .data = "" });
	const base = try tmp.dir.realPathFileAlloc(io, ".", alloc);
	defer alloc.free(base);
	const f = try std.fs.path.join(alloc, &.{ base, "f" });
	defer alloc.free(f);

	const value = "a\x00b\n\xff";
	xs.set(f, "probe", value, .{}) catch |e| switch (e) {
		error.Unsupported => return error.SkipZigTest,
		else => return e,
	};
	const got = try xs.get(alloc, f, "probe", .{});
	defer alloc.free(got);
	try std.testing.expectEqualSlices(u8, value, got);
	try std.testing.expectError(error.InvalidName, xs.set(f, "a:b", "v", .{}));
	try xs.remove(f, "probe", .{});
	try std.testing.expectError(error.Missing, xs.size(f, "probe", .{}));
	try std.testing.expectEqual(@as(c_int, 1), xs.statusCode(error.Missing));
}
