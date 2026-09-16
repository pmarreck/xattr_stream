const std = @import("std");

/// Every target the library and CLI are cross-compiled for by `zig build cross`.
/// Runtime verification happens only where a machine is available; see README.
const cross_targets = [_][]const u8{
	"x86_64-linux-musl",
	"aarch64-linux-musl",
	"aarch64-macos",
	"x86_64-windows-gnu",
	"aarch64-windows-gnu",
};

const c_flags = [_][]const u8{ "-std=c11", "-Wall", "-Wextra", "-Werror" };

const Artifacts = struct {
	static: *std.Build.Step.Compile,
	shared: *std.Build.Step.Compile,
	cli: *std.Build.Step.Compile,
};

/// The Zig core links libc only where the OS adapter needs it (macOS
/// libSystem). Linux uses raw syscalls; Windows imports kernel32 directly.
fn coreNeedsLibc(target: std.Build.ResolvedTarget) bool {
	return target.result.os.tag == .macos;
}

/// On Linux the CLI is built against musl so it is a fully static binary that
/// runs on any distribution (and inside the Nix sandbox, which has no
/// /lib64 loader for a glibc-linked executable). Libraries keep the
/// requested target so consumers link against their own libc.
fn cliTarget(b: *std.Build, target: std.Build.ResolvedTarget) std.Build.ResolvedTarget {
	if (target.result.os.tag != .linux or target.result.abi.isMusl()) return target;
	var q = target.query;
	q.abi = .musl;
	return b.resolveTargetQuery(q);
}

/// src/ffi.zig is the ONLY root that defines `export fn xs_*`; the
/// importable `xattr_stream` module never emits C symbols.
fn staticLib(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
	const mod = b.createModule(.{
		.root_source_file = b.path("src/ffi.zig"),
		.target = target,
		.optimize = optimize,
		.pic = true,
		.link_libc = coreNeedsLibc(target),
	});
	return b.addLibrary(.{
		.name = "xattr_stream",
		.linkage = .static,
		.root_module = mod,
	});
}

fn makeArtifacts(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) Artifacts {
	const libc = coreNeedsLibc(target);
	const static_lib = staticLib(b, target, optimize);

	const shared_mod = b.createModule(.{
		.root_source_file = b.path("src/ffi.zig"),
		.target = target,
		.optimize = optimize,
		.pic = true,
		.link_libc = libc,
	});
	const shared_lib = b.addLibrary(.{
		.name = "xattr_stream",
		.linkage = .dynamic,
		.root_module = shared_mod,
	});

	// The CLI is C and reaches the core only through include/xattr_stream.h.
	const cli_tgt = cliTarget(b, target);
	const cli_lib = if (cli_tgt.result.abi == target.result.abi) static_lib else staticLib(b, cli_tgt, optimize);
	const cli_mod = b.createModule(.{
		.target = cli_tgt,
		.optimize = optimize,
		.link_libc = true,
	});
	cli_mod.addIncludePath(b.path("include"));
	cli_mod.addCSourceFile(.{ .file = b.path("src/xattr_stream_cli.c"), .flags = &c_flags });
	cli_mod.linkLibrary(cli_lib);
	const cli = b.addExecutable(.{
		.name = "xattr-stream",
		.root_module = cli_mod,
	});

	return .{ .static = static_lib, .shared = shared_lib, .cli = cli };
}

pub fn build(b: *std.Build) void {
	const target = b.standardTargetOptions(.{});
	const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Optimization mode (default: ReleaseFast)") orelse .ReleaseFast;

	// Importable Zig module for sibling Zig projects (no C exports).
	_ = b.addModule("xattr_stream", .{
		.root_source_file = b.path("src/xattr_stream.zig"),
		.target = target,
		.optimize = optimize,
		.link_libc = coreNeedsLibc(target),
	});

	const native = makeArtifacts(b, target, optimize);
	b.installArtifact(native.static);
	// The DLL import library would collide with the static .lib on Windows;
	// C and Rust consumers link the static library, LuaJIT loads the DLL/.so.
	b.getInstallStep().dependOn(&b.addInstallArtifact(native.shared, .{ .implib_dir = .disabled }).step);
	b.installArtifact(native.cli);
	b.installFile("include/xattr_stream.h", "include/xattr_stream.h");

	const lib_step = b.step("lib", "Build only the static and shared libraries");
	lib_step.dependOn(&native.static.step);
	lib_step.dependOn(&native.shared.step);

	// Unit + integration tests. Each root pulls in its own test declarations.
	const test_step = b.step("test", "Run Zig unit and integration tests");
	const test_roots = [_][]const u8{ "src/xattr_stream.zig", "src/ffi.zig", "src/names.zig" };
	for (test_roots) |root| {
		const t = b.addTest(.{
			.root_module = b.createModule(.{
				.root_source_file = b.path(root),
				.target = target,
				.optimize = optimize,
				.link_libc = coreNeedsLibc(target),
			}),
		});
		test_step.dependOn(&b.addRunArtifact(t).step);
	}

	// Cross-compile every supported target into zig-out/cross/<triple>/.
	const cross_step = b.step("cross", "Cross-compile library and CLI for all supported targets");
	for (cross_targets) |triple| {
		const query = std.Target.Query.parse(.{ .arch_os_abi = triple }) catch unreachable;
		const rt = b.resolveTargetQuery(query);
		const arts = makeArtifacts(b, rt, optimize);
		const lib_dir = b.fmt("cross/{s}/lib", .{triple});
		const bin_dir = b.fmt("cross/{s}/bin", .{triple});
		cross_step.dependOn(&b.addInstallArtifact(arts.static, .{
			.dest_dir = .{ .override = .{ .custom = lib_dir } },
		}).step);
		cross_step.dependOn(&b.addInstallArtifact(arts.shared, .{
			.dest_dir = .{ .override = .{ .custom = lib_dir } },
			.implib_dir = .disabled,
			.pdb_dir = .disabled,
		}).step);
		cross_step.dependOn(&b.addInstallArtifact(arts.cli, .{
			.dest_dir = .{ .override = .{ .custom = bin_dir } },
			.pdb_dir = .disabled,
		}).step);
	}
}
