-- Seeded fixture and case generator for tests/cli/differential.sh.
--   luajit differential_gen.lua tree <seed> <valsdir> <nonutf:0|1>
--   luajit differential_gen.lua fuzz <seed> <count>
-- `tree` prints a Bash script (setup commands, then `path`/`attr`
-- registrations) and writes attribute values into <valsdir>. `fuzz` prints
-- dump lines, valid ones and seeded corruptions of them, for `load`.
-- Deterministic for a seed: xorshift32, not math.random, so every LuaJIT
-- build produces the same fixture.
local bit = require("bit")
local mode, seed = arg[1], tonumber(arg[2])
local state = (seed % 4294967296) ~= 0 and seed % 4294967296 or 2463534242

local function rnd(n) -- uniform integer in [1, n]
	local x = state
	x = bit.bxor(x, bit.lshift(x, 13))
	x = bit.bxor(x, bit.rshift(x, 17))
	x = bit.bxor(x, bit.lshift(x, 5))
	state = x % 4294967296
	return state % n + 1
end
local function pick(t) return t[rnd(#t)] end

-- Bash ANSI-C quoting, every byte outside a safe set as \xNN.
local function q(s)
	return "$'" .. s:gsub("[^%w%._/%-]", function(c) return string.format("\\x%02x", c:byte()) end) .. "'"
end

if mode == "tree" then
	local valsdir, nonutf = arg[3], arg[4] == "1"
	local file_names = { "a", "b c", "dir with space", "ünï", "pipe|bar", "comma,name", 'quote"q', "x.y", "tab-less", "z", "ctl\31char" }
	if nonutf then file_names[#file_names + 1] = "caf\xe9" end
	-- Valid logical names only: the fixture is built through the CLI itself.
	local attr_names = { "k", "user_data", "with space", "ünïcödé", "x.y.z", "comma,in", "semi;colon", "brace{}", string.rep("n", 127), "Z", "a.b", "~tilde", "#hash" }
	local nval = 0
	local function value()
		local kind = rnd(10)
		local out = {}
		if kind == 1 then return "" end
		if kind <= 4 then -- printable text, spaces and tabs included
			local alphabet = { "a", "b", "Z", "0", " ", "\t", "é", "∣", "|", ",", '"', "\\", "~", "!", "." }
			for _ = 1, rnd(24) do out[#out + 1] = pick(alphabet) end
		elseif kind <= 8 then -- binary
			for _ = 1, rnd(48) do out[#out + 1] = string.char(rnd(256) - 1) end
		elseif kind == 9 then -- multi-line text
			for _ = 1, rnd(4) do out[#out + 1] = "line " .. rnd(99) .. "\n" end
		else -- longer than the 4 KiB optimistic read and the 3916 portability bound
			for _ = 1, 4000 + rnd(200) do out[#out + 1] = string.char(rnd(256) - 1) end
		end
		return table.concat(out)
	end
	local function attrs(rel)
		local used = {}
		for _ = 1, rnd(5) - 1 do
			local n = pick(attr_names)
			if not used[n] then
				used[n] = true
				nval = nval + 1
				local f = assert(io.open(valsdir .. "/" .. nval, "wb"))
				f:write(value())
				f:close()
				print("put " .. q(rel) .. " " .. q(n) .. " " .. q(valsdir .. "/" .. nval))
				print("attr " .. q(rel) .. " " .. q(n))
			end
		end
	end
	local function dir(rel, depth)
		print("path " .. q(rel))
		attrs(rel)
		local used = {}
		for _ = 1, rnd(4) + 1 do
			local n = pick(file_names)
			if not used[n] then
				used[n] = true
				local child = rel .. "/" .. n
				if depth < 3 and rnd(3) == 1 then
					print("mkdir " .. q(child))
					dir(child, depth + 1)
				else
					print("touch " .. q(child))
					print("path " .. q(child))
					attrs(child)
				end
			end
		end
	end
	print("mkdir " .. q("t"))
	dir("t", 1)
	print("touch " .. q("t/linked"))
	print("ln -s linked " .. q("t/link"))
	print("ln -s nowhere " .. q("t/dangling"))
	print("path " .. q("t/link"))
elseif mode == "fuzz" then
	local count = tonumber(arg[3])
	local templates = {
		'{"path":"f1","xattrs":{"k":"v","with space":"a b"}}',
		'{"path_pb":"f2","xattrs":{"bin":"·¯żŻ"}}',
		'{"path":"f1","xattrs_pb":{"Ĺǧ":"x"},"xattrs":{"e":""}}',
		'{"path":"d/f3","xattrs":{"k":"\\u00e9\\t\\"q\\"\\\\"}}',
		'{ "xattrs" : { "k2" : "2" } , "path" : "f2" }',
		'{"path":"../escape","xattrs":{"k":"v"}}',
		'{"path":"/abs","xattrs":{"k":"v"}}',
		'{"path":"f1","xattrs":{"user.k":"v","a:b":"v","":"v"}}',
		'{"path":"missing","xattrs":{"k":"v"}}',
		'{"path":"f1","xattrs_pb":{"":"v"}}',
	}
	local noise = { "{", "}", "[", "]", '"', ":", ",", "\\", "u", "d", "8", "0", "0", " ", "\t", "\xff", "\xc3", "\x00", "é", "\\ud800", "\\udc00", "\\u0041", "path", "xattrs", "_pb", "1", "null" }
	for _ = 1, count do
		local line = pick(templates)
		for _ = 1, rnd(4) - 1 do
			local at = rnd(#line + 1) - 1
			local op = rnd(3)
			if op == 1 then
				line = line:sub(1, at) .. pick(noise) .. line:sub(at + 1)
			elseif op == 2 then
				line = line:sub(1, at) .. line:sub(at + 1 + rnd(3))
			else
				local from = rnd(#line)
				line = line:sub(1, at) .. line:sub(from, from + rnd(6)) .. line:sub(at + 1)
			end
		end
		print((line:gsub("\n", " ")))
	end
else
	io.stderr:write("usage: differential_gen.lua tree|fuzz ...\n")
	os.exit(2)
end
