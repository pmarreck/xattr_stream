#!/usr/bin/env luajit
-- Independent LuaJIT consumer of the C ABI through the shared library.
-- Usage: luajit consumer.lua path/to/libxattr_stream.so
-- Creates its own fixture file in the current directory and removes it.
local ffi = require("ffi")

local libpath = arg[1]
if not libpath then
	io.stderr:write("usage: consumer.lua <libxattr_stream shared library>\n")
	os.exit(2)
end

ffi.cdef[[
typedef struct xs_options { uint32_t flags; uint64_t max_value_len; } xs_options;
typedef struct xs_buffer { uint8_t *data; size_t len; size_t cap; } xs_buffer;
int xs_set(const char *path, size_t path_len, const char *name, size_t name_len, const void *value, size_t value_len, const xs_options *opts);
int xs_size(const char *path, size_t path_len, const char *name, size_t name_len, const xs_options *opts, uint64_t *out_len);
int xs_get(const char *path, size_t path_len, const char *name, size_t name_len, const xs_options *opts, xs_buffer *out);
int xs_remove(const char *path, size_t path_len, const char *name, size_t name_len, const xs_options *opts);
int xs_list(const char *path, size_t path_len, const xs_options *opts, xs_buffer *out, size_t *out_count);
void xs_buffer_free(xs_buffer *buf);
const char *xs_status_name(int status);
const char *xs_version(void);
const char *xs_target(void);
]]

local lib = ffi.load(libpath)
local XS_OK, XS_MISSING, XS_UNSUPPORTED, XS_INVALID_NAME = 0, 1, 2, 7

local failures = 0
local function check(cond, msg)
	if not cond then
		failures = failures + 1
		io.stderr:write("FAIL: " .. msg .. "\n")
	end
end

local path = "xs_consumer_lua.tmp"
local f = assert(io.open(path, "wb"))
f:close()

local parts = {}
for i = 0, 255 do parts[#parts + 1] = string.char(i) end
local all = table.concat(parts)

local st = lib.xs_set(path, #path, "probe", 5, all, #all, nil)
if st == XS_UNSUPPORTED then
	io.stderr:write("SKIP: filesystem does not support attributes\n")
	os.remove(path)
	os.exit(0)
end
check(st == XS_OK, "xs_set")

local len = ffi.new("uint64_t[1]")
check(lib.xs_size(path, #path, "probe", 5, nil, len) == XS_OK and tonumber(len[0]) == 256, "xs_size == 256")

local buf = ffi.new("xs_buffer")
check(lib.xs_get(path, #path, "probe", 5, nil, buf) == XS_OK, "xs_get")
local got = ffi.string(buf.data, buf.len)
lib.xs_buffer_free(buf)
check(got == all, "round trip bytes (with NUL and 0xFF)")
check(buf.data == nil and tonumber(buf.len) == 0, "xs_buffer_free zeroes")

local names = ffi.new("xs_buffer")
local count = ffi.new("size_t[1]")
check(lib.xs_list(path, #path, nil, names, count) == XS_OK and tonumber(count[0]) == 1, "xs_list count 1")
check(ffi.string(names.data, names.len) == "probe\0", "xs_list packing")
lib.xs_buffer_free(names)

check(lib.xs_set(path, #path, "a:b", 3, "v", 1, nil) == XS_INVALID_NAME, "invalid name")
check(ffi.string(lib.xs_status_name(XS_INVALID_NAME)) == "XS_INVALID_NAME", "status name")
check(lib.xs_remove(path, #path, "probe", 5, nil) == XS_OK, "xs_remove")
check(lib.xs_size(path, #path, "probe", 5, nil, len) == XS_MISSING, "size after remove")

os.remove(path)
if failures == 0 then
	print(string.format("LuaJIT consumer: ok (%s, %s)", ffi.string(lib.xs_version()), ffi.string(lib.xs_target())))
end
os.exit(failures)
