//! How attribute tests treat a filesystem that refuses attributes. They fail
//! unless the run declares that case up front with XS_EXPECT_UNSUPPORTED=1
//! (the Nix build sandbox, whose seccomp filter refuses setxattr on every
//! filesystem); then they are skipped, and Zig reports them as skipped.
const std = @import("std");

pub const fatal_hint = "does not support attributes; set XS_EXPECT_UNSUPPORTED=1 where that is expected";

pub fn expectUnsupported() bool {
	const v = std.testing.environ.getAlloc(std.testing.allocator, "XS_EXPECT_UNSUPPORTED") catch return false;
	defer std.testing.allocator.free(v);
	return std.mem.eql(u8, v, "1");
}

/// Called when the fixture probe got Unsupported: skip if declared, else fail loudly.
pub fn unsupported(where: []const u8) error{ SkipZigTest, NoAttributeSupport } {
	if (expectUnsupported()) return error.SkipZigTest;
	std.debug.print("{s} " ++ fatal_hint ++ "\n", .{where});
	return error.NoAttributeSupport;
}
