//! Tests of the C ABI as a C caller would use it (tests-first). Exercises
//! NULL/length conventions, ownership via xs_buffer_free, and status codes.
const std = @import("std");
const ffi = @import("ffi.zig");
const io = std.testing.io;
const alloc = std.testing.allocator;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

const Fixture = struct {
	tmp: std.testing.TmpDir,
	file: []u8,

	fn init() !Fixture {
		var tmp = std.testing.tmpDir(.{});
		errdefer tmp.cleanup();
		try tmp.dir.writeFile(io, .{ .sub_path = "f", .data = "" });
		const base = try tmp.dir.realPathFileAlloc(io, ".", alloc);
		defer alloc.free(base);
		const file = try std.fs.path.join(alloc, &.{ base, "f" });
		errdefer alloc.free(file);
		// Same skip rule as the core fixture: no attribute support, no verdict.
		if (ffi.xs_set(file.ptr, file.len, "probe", 5, "x", 1, null) == ffi.XS_UNSUPPORTED) {
			std.debug.print("SKIP: {s} does not support attributes\n", .{base});
			return error.SkipZigTest;
		}
		_ = ffi.xs_remove(file.ptr, file.len, "probe", 5, null);
		return .{ .tmp = tmp, .file = file };
	}

	fn deinit(self: *Fixture) void {
		alloc.free(self.file);
		self.tmp.cleanup();
	}
};

test "xs_set / xs_size / xs_get / xs_buffer_free round trip with byte lengths" {
	var fx = try Fixture.init();
	defer fx.deinit();
	const value = "a\x00b\n\xff";
	try expectEqual(ffi.XS_OK, ffi.xs_set(fx.file.ptr, fx.file.len, "k", 1, value.ptr, value.len, null));
	var len: u64 = 0;
	try expectEqual(ffi.XS_OK, ffi.xs_size(fx.file.ptr, fx.file.len, "k", 1, null, &len));
	try expectEqual(@as(u64, 5), len);
	var buf: ffi.xs_buffer = .{ .data = null, .len = 0, .cap = 0 };
	try expectEqual(ffi.XS_OK, ffi.xs_get(fx.file.ptr, fx.file.len, "k", 1, null, &buf));
	try std.testing.expectEqualSlices(u8, value, buf.data.?[0..buf.len]);
	ffi.xs_buffer_free(&buf);
	try expect(buf.data == null);
	try expectEqual(@as(usize, 0), buf.len);
	// Double free is a no-op by contract.
	ffi.xs_buffer_free(&buf);
}

test "xs_get_into honours the caller buffer and reports XS_BUFFER_TOO_SMALL" {
	var fx = try Fixture.init();
	defer fx.deinit();
	try expectEqual(ffi.XS_OK, ffi.xs_set(fx.file.ptr, fx.file.len, "k", 1, "hello", 5, null));
	var small: [4]u8 = undefined;
	var got: usize = 0;
	try expectEqual(ffi.XS_BUFFER_TOO_SMALL, ffi.xs_get_into(fx.file.ptr, fx.file.len, "k", 1, &small, small.len, null, &got));
	var exact: [5]u8 = undefined;
	try expectEqual(ffi.XS_OK, ffi.xs_get_into(fx.file.ptr, fx.file.len, "k", 1, &exact, exact.len, null, &got));
	try expectEqual(@as(usize, 5), got);
	try expectEqualStrings("hello", &exact);
}

test "xs_list packs NUL-terminated logical names and counts them" {
	var fx = try Fixture.init();
	defer fx.deinit();
	try expectEqual(ffi.XS_OK, ffi.xs_set(fx.file.ptr, fx.file.len, "one", 3, "1", 1, null));
	try expectEqual(ffi.XS_OK, ffi.xs_set(fx.file.ptr, fx.file.len, "two", 3, "", 0, null));
	var buf: ffi.xs_buffer = .{ .data = null, .len = 0, .cap = 0 };
	var count: usize = 0;
	try expectEqual(ffi.XS_OK, ffi.xs_list(fx.file.ptr, fx.file.len, null, &buf, &count));
	defer ffi.xs_buffer_free(&buf);
	try expectEqual(@as(usize, 2), count);
	const bytes = buf.data.?[0..buf.len];
	try expectEqual(@as(usize, 8), bytes.len);
	try expect(std.mem.indexOf(u8, bytes, "one\x00") != null);
	try expect(std.mem.indexOf(u8, bytes, "two\x00") != null);
}

test "status codes: missing, not found, invalid name, invalid path, and their names" {
	var fx = try Fixture.init();
	defer fx.deinit();
	var len: u64 = 0;
	try expectEqual(ffi.XS_MISSING, ffi.xs_size(fx.file.ptr, fx.file.len, "nope", 4, null, &len));
	const gone = "/definitely/not/here";
	try expectEqual(ffi.XS_NOT_FOUND, ffi.xs_size(gone, gone.len, "k", 1, null, &len));
	try expectEqual(ffi.XS_INVALID_NAME, ffi.xs_size(fx.file.ptr, fx.file.len, "a:b", 3, null, &len));
	try expectEqual(ffi.XS_INVALID_PATH, ffi.xs_size("", 0, "k", 1, null, &len));
	try expectEqual(ffi.XS_INVALID_PATH, ffi.xs_size(null, 3, "k", 1, null, &len));
	try expectEqual(ffi.XS_INVALID_NAME, ffi.xs_size(fx.file.ptr, fx.file.len, null, 3, null, &len));
	try expectEqualStrings("XS_MISSING", std.mem.span(ffi.xs_status_name(ffi.XS_MISSING)));
	try expectEqualStrings("XS_UNKNOWN", std.mem.span(ffi.xs_status_name(999)));
	try expect(ffi.xs_last_os_error() != 0);
}

test "options: flags and max_value_len are honoured; NULL means defaults" {
	var fx = try Fixture.init();
	defer fx.deinit();
	const tight = ffi.xs_options{ .flags = 0, .max_value_len = 3 };
	try expectEqual(ffi.XS_TOO_LARGE, ffi.xs_set(fx.file.ptr, fx.file.len, "k", 1, "toolong", 7, &tight));
	try expectEqual(ffi.XS_OK, ffi.xs_set(fx.file.ptr, fx.file.len, "k", 1, "toolong", 7, null));
	var buf: ffi.xs_buffer = .{ .data = null, .len = 0, .cap = 0 };
	try expectEqual(ffi.XS_TOO_LARGE, ffi.xs_get(fx.file.ptr, fx.file.len, "k", 1, &tight, &buf));
	try expect(buf.data == null);

	// Raw flag addresses the native name directly.
	var nbuf: [512]u8 = undefined;
	var nlen: usize = 0;
	try expectEqual(ffi.XS_OK, ffi.xs_native_name("k", 1, null, &nbuf, nbuf.len, &nlen));
	const raw = ffi.xs_options{ .flags = ffi.XS_FLAG_RAW_NAMES, .max_value_len = 0 };
	var len: u64 = 0;
	try expectEqual(ffi.XS_OK, ffi.xs_size(fx.file.ptr, fx.file.len, &nbuf, nlen, &raw, &len));
	try expectEqual(@as(u64, 7), len);
	try expectEqual(ffi.XS_OK, ffi.xs_remove(fx.file.ptr, fx.file.len, "k", 1, null));
	try expectEqual(ffi.XS_MISSING, ffi.xs_remove(fx.file.ptr, fx.file.len, "k", 1, null));
}

test "xs_version and xs_target are stable static strings" {
	try expectEqualStrings("0.2.0", std.mem.span(ffi.xs_version()));
	const target = std.mem.span(ffi.xs_target());
	try expect(std.mem.indexOf(u8, target, "-") != null);
	try expect(ffi.xs_limits("", 0) == -1);
}
