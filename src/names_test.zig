//! Classifier tests for the logical attribute-name policy (tests-first).
//! Names are tested as SETS (accept set / reject set with reason), never as
//! single presence checks, per the fleet testing brief.
const std = @import("std");
const names = @import("names.zig");
const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;

const all_os = [_]names.Os{ .linux, .macos, .windows };

const accept_set = [_][]const u8{
	"a",
	"llc.mecha.probe",
	"user_data",
	"com.example.app",
	"x.y.z",
	"with-dash",
	"ünïcödé",
	"a" ** names.max_logical_len,
	"security.selinux", // logical namespace-looking names are just names
};

test "accept set: valid logical names map to the documented native form on every OS" {
	var buf: [names.native_buf_len]u8 = undefined;
	for (accept_set) |name| {
		try expect(names.validateLogical(name) == null);
		for (all_os) |os| {
			const native = try names.toNative(os, name, .{}, &buf);
			switch (os) {
				.linux => {
					try expect(std.mem.startsWith(u8, native, "user."));
					try expectEqualStrings(name, native["user.".len..]);
				},
				.macos, .windows => try expectEqualStrings(name, native),
			}
			// Bijection: the native form maps back to exactly the logical name.
			const back = names.fromNative(os, native, .{}) orelse return error.TestUnexpectedResult;
			try expectEqualStrings(name, back);
		}
	}
}

const Rejected = struct { name: []const u8, why: names.Rejection };
const reject_set = [_]Rejected{
	.{ .name = "", .why = .empty },
	.{ .name = "a\x00b", .why = .control_char },
	.{ .name = "a\nb", .why = .control_char },
	.{ .name = "a\x7fb", .why = .control_char },
	.{ .name = "a/b", .why = .forbidden_char },
	.{ .name = "a\\b", .why = .forbidden_char },
	.{ .name = "a:b", .why = .forbidden_char },
	.{ .name = "a*b", .why = .forbidden_char },
	.{ .name = "a?b", .why = .forbidden_char },
	.{ .name = "a\"b", .why = .forbidden_char },
	.{ .name = "a<b", .why = .forbidden_char },
	.{ .name = "a>b", .why = .forbidden_char },
	.{ .name = "a|b", .why = .forbidden_char },
	.{ .name = "..\\x", .why = .forbidden_char },
	.{ .name = "user.foo", .why = .linux_namespace },
	.{ .name = "User.Foo", .why = .linux_namespace },
	.{ .name = "USER.x", .why = .linux_namespace },
	.{ .name = "$DATA", .why = .reserved },
	.{ .name = "$foo", .why = .reserved },
	.{ .name = "Zone.Identifier", .why = .reserved },
	.{ .name = "zone.identifier", .why = .reserved },
	.{ .name = "com.apple.quarantine", .why = .reserved },
	.{ .name = "COM.APPLE.FinderInfo", .why = .reserved },
	.{ .name = "a" ** (names.max_logical_len + 1), .why = .too_long },
	.{ .name = "\xff\xfe", .why = .not_utf8 },
	.{ .name = "trailing.", .why = .edge_whitespace_or_dot },
	.{ .name = "trailing ", .why = .edge_whitespace_or_dot },
	.{ .name = " leading", .why = .edge_whitespace_or_dot },
	.{ .name = ".", .why = .edge_whitespace_or_dot },
	.{ .name = "..", .why = .edge_whitespace_or_dot },
};

test "reject set: every invalid logical name is rejected with the expected reason on every OS" {
	var buf: [names.native_buf_len]u8 = undefined;
	for (reject_set) |case| {
		const why = names.validateLogical(case.name) orelse {
			std.debug.print("expected rejection of {x}\n", .{case.name});
			return error.TestUnexpectedResult;
		};
		try std.testing.expectEqual(case.why, why);
		for (all_os) |os| {
			try expectError(error.InvalidName, names.toNative(os, case.name, .{}, &buf));
		}
	}
}

test "fromNative hides names that are not reachable from the logical layer" {
	// Linux: only the user namespace is visible logically; other namespaces are hidden.
	try expect(names.fromNative(.linux, "security.selinux", .{}) == null);
	try expect(names.fromNative(.linux, "trusted.x", .{}) == null);
	try expect(names.fromNative(.linux, "user.", .{}) == null);
	try expect(names.fromNative(.linux, "bare", .{}) == null);
	// macOS: OS-reserved names are hidden.
	try expect(names.fromNative(.macos, "com.apple.quarantine", .{}) == null);
	// Windows: NTFS-reserved and Mark-of-the-Web streams are hidden.
	try expect(names.fromNative(.windows, "$I30", .{}) == null);
	try expect(names.fromNative(.windows, "Zone.Identifier", .{}) == null);
}

test "raw mode passes native names through with only OS hard limits enforced" {
	var buf: [names.native_buf_len]u8 = undefined;
	const raw = names.NameOptions{ .raw = true };
	try expectEqualStrings("security.selinux", try names.toNative(.linux, "security.selinux", raw, &buf));
	try expectEqualStrings("bare", try names.toNative(.linux, "bare", raw, &buf));
	try expectEqualStrings("com.apple.quarantine", try names.toNative(.macos, "com.apple.quarantine", raw, &buf));
	try expectEqualStrings("Zone.Identifier", try names.toNative(.windows, "Zone.Identifier", raw, &buf));
	try expectEqualStrings("security.selinux", names.fromNative(.linux, "security.selinux", raw).?);
	// Hard limits still apply in raw mode.
	try expectError(error.InvalidName, names.toNative(.linux, "", raw, &buf));
	try expectError(error.InvalidName, names.toNative(.linux, "a\x00b", raw, &buf));
	try expectError(error.InvalidName, names.toNative(.linux, "a" ** 256, raw, &buf));
	try expectError(error.InvalidName, names.toNative(.macos, "a" ** 128, raw, &buf));
	try expectError(error.InvalidName, names.toNative(.windows, "a" ** 256, raw, &buf));
	// Path injection is rejected on Windows even in raw mode: these change the path, not the name.
	try expectError(error.InvalidName, names.toNative(.windows, "a:b", raw, &buf));
	try expectError(error.InvalidName, names.toNative(.windows, "a\\b", raw, &buf));
	try expectError(error.InvalidName, names.toNative(.windows, "a/b", raw, &buf));
}

test "native results are sentinel terminated and fit the buffer contract" {
	var buf: [names.native_buf_len]u8 = undefined;
	const n = try names.toNative(.linux, "a" ** names.max_logical_len, .{}, &buf);
	try std.testing.expectEqual(@as(u8, 0), n[n.len]);
	try std.testing.expectEqual("user.".len + names.max_logical_len, n.len);
	try expect(n.len < names.native_buf_len);
}
