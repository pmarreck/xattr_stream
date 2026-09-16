//! Logical attribute-name policy: one portable name grammar mapped onto each
//! OS's native rules. Pure computation, no I/O, no allocation.
//!
//! Logical mode (default): the caller's name has no OS namespace. Linux stores
//! it under `user.<name>`; macOS and Windows store it verbatim. The mapping is a
//! bijection, so `fromNative(toNative(x)) == x`, and native names that are not
//! reachable from the logical layer (other Linux namespaces, `com.apple.*`,
//! NTFS `$` streams, `Zone.Identifier`) are hidden from logical listings.
//!
//! Raw mode: names pass through untouched except for hard OS limits and, on
//! Windows, the three path-injection characters (`:`, `\`, `/`).
const std = @import("std");

pub const Os = enum { linux, macos, windows };

pub const NameOptions = struct {
	raw: bool = false,
};

pub const Rejection = enum {
	empty,
	too_long,
	control_char,
	forbidden_char,
	reserved,
	not_utf8,
	edge_whitespace_or_dot,
};

pub const NameError = error{InvalidName};

/// macOS XATTR_MAXNAMELEN (127) is the strictest of the three targets, so it
/// bounds the portable grammar.
pub const max_logical_len = 127;
pub const linux_user_prefix = "user.";
/// Largest native name (Linux/Windows: 255) plus the NUL terminator.
pub const native_buf_len = 256 + 1;

/// Characters that are illegal in Windows stream names or would inject a path
/// component; rejected on every OS so a portable name is valid everywhere.
const forbidden_chars = "/\\:*?\"<>|";
/// Windows path-injection characters, rejected even in raw mode.
const windows_injection_chars = ":\\/";
const reserved_prefixes_ci = [_][]const u8{ "com.apple.", "$" };
const reserved_exact_ci = [_][]const u8{"zone.identifier"};

pub fn maxNativeLen(os: Os) usize {
	return switch (os) {
		.linux, .windows => 255,
		.macos => 127,
	};
}

/// Classify a logical name. Returns null when the name is acceptable on every
/// supported OS, otherwise the first reason it is not.
pub fn validateLogical(name: []const u8) ?Rejection {
	if (name.len == 0) return .empty;
	if (name.len > max_logical_len) return .too_long;
	for (name) |c| {
		if (c < 0x20 or c == 0x7f) return .control_char;
		if (std.mem.indexOfScalar(u8, forbidden_chars, c) != null) return .forbidden_char;
	}
	if (!std.unicode.utf8ValidateSlice(name)) return .not_utf8;
	const last = name[name.len - 1];
	if (name[0] == ' ' or last == ' ' or last == '.') return .edge_whitespace_or_dot;
	for (reserved_prefixes_ci) |p| {
		if (std.ascii.startsWithIgnoreCase(name, p)) return .reserved;
	}
	for (reserved_exact_ci) |e| {
		if (std.ascii.eqlIgnoreCase(name, e)) return .reserved;
	}
	return null;
}

/// Map a caller-facing name to the NUL-terminated native name for `os`,
/// written into `buf` (at least `native_buf_len` bytes).
pub fn toNative(os: Os, name: []const u8, opts: NameOptions, buf: []u8) NameError![:0]u8 {
	if (opts.raw) {
		if (name.len == 0 or name.len > maxNativeLen(os)) return error.InvalidName;
		if (std.mem.indexOfScalar(u8, name, 0) != null) return error.InvalidName;
		if (os == .windows) {
			for (name) |c| {
				if (std.mem.indexOfScalar(u8, windows_injection_chars, c) != null) return error.InvalidName;
			}
			if (!std.unicode.utf8ValidateSlice(name)) return error.InvalidName;
		}
		return writeZ(buf, &.{name});
	}
	if (validateLogical(name) != null) return error.InvalidName;
	return switch (os) {
		.linux => writeZ(buf, &.{ linux_user_prefix, name }),
		.macos, .windows => writeZ(buf, &.{name}),
	};
}

/// Inverse of `toNative`. Returns null for native names the logical layer
/// cannot produce, so listings never show names a caller could not address.
pub fn fromNative(os: Os, native: []const u8, opts: NameOptions) ?[]const u8 {
	if (opts.raw) return native;
	const logical = switch (os) {
		.linux => if (std.mem.startsWith(u8, native, linux_user_prefix)) native[linux_user_prefix.len..] else return null,
		.macos, .windows => native,
	};
	if (validateLogical(logical) != null) return null;
	return logical;
}

fn writeZ(buf: []u8, parts: []const []const u8) NameError![:0]u8 {
	var total: usize = 0;
	for (parts) |p| total += p.len;
	if (total + 1 > buf.len) return error.InvalidName;
	var i: usize = 0;
	for (parts) |p| {
		@memcpy(buf[i..][0..p.len], p);
		i += p.len;
	}
	buf[i] = 0;
	return buf[0..i :0];
}

test {
	_ = @import("names_test.zig");
}
