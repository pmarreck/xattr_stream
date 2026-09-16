//! A sibling Zig project consuming xattr_stream as a path dependency and
//! importing the `xattr_stream` module directly (no C ABI involved).
const std = @import("std");

pub fn build(b: *std.Build) void {
	const target = b.standardTargetOptions(.{});
	const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Optimization mode") orelse .ReleaseSafe;
	const dep = b.dependency("xattr_stream", .{ .target = target, .optimize = optimize });

	const t = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("consumer.zig"),
			.target = target,
			.optimize = optimize,
			.imports = &.{
				.{ .name = "xattr_stream", .module = dep.module("xattr_stream") },
			},
		}),
	});
	const test_step = b.step("test", "Run the Zig consumer round trip");
	test_step.dependOn(&b.addRunArtifact(t).step);
}
