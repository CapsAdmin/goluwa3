local bit = require("bit")
local util = require("jit.util")
local ffi = require("ffi")
local resolve_import_path = require("goluwa.require").ResolveImportPath
local funcbc = util.funcbc
local funck = util.funck
local funcinfo = util.funcinfo
local funcuvname = util.funcuvname
local names = require("jit.vmdef").bcnames
local band = bit.band
local rshift = bit.rshift
-- the argument of a call sits after the slot that links the frame on 64 bit
local argument_slot = ffi.abi("gc64") and 2 or 1
local opcodes = {}

local function clear_from(registers, base)
	for register in pairs(registers) do
		if register >= base then registers[register] = nil end
	end
end

-- A module that reads from another one while it loads, by calling it (a glsl builder) or taking a
-- value out of it, has consumed what it had. That shows in the bytecode as a table read from the
-- register an import() result went into, in the main chunk or in a local function the main chunk
-- calls on the way. Functions that are only called later look the module up again every time.
-- Returns the set of module paths that were used.
return function(chunk, importer)
	local uses = {}
	local aliases = {}
	local lines
	local source = debug.getinfo(chunk, "S").source
	local file = source:sub(1, 1) == "@" and io.open(source:sub(2), "rb")

	if file then
		local text = file:read("*a")
		file:close()

		for name, literal in text:gmatch("local%s+([%w_]+)%s*=%s*import%(%s*[\"']([^\"']+)[\"']%s*%)") do
			aliases[name] = resolve_import_path(literal, importer)
		end

		lines = {}

		for line in (text .. "\n"):gmatch("(.-)\r?\n") do
			lines[#lines + 1] = line
		end
	end

	local functions_by_name = {}
	local visited = {}

	local function run(proto)
		if visited[proto] then return end

		visited[proto] = true
		local dependency_of = {}
		local is_import = {}
		local strings = {}
		local proto_at = {}

		for pc = 1, math.huge do
			local ins, mode = funcbc(proto, pc)

			if not ins then break end

			local opcode = band(ins, 0xff)
			local op = opcodes[opcode]

			if not op then
				op = names:sub(6 * opcode + 1, 6 * opcode + 6):gsub("%s+$", "")
				opcodes[opcode] = op
			end

			local a = band(rshift(ins, 8), 0xff)
			local d = rshift(ins, 16)

			if op:sub(1, 4) == "TGET" then
				local dependency = dependency_of[rshift(ins, 24)]

				if dependency then uses[dependency] = true end
			end

			if op == "CALL" or op == "CALLM" or op == "CALLT" or op == "CALLMT" then
				local literal = is_import[a] and
					(
						strings[a + argument_slot] or
						strings[a + argument_slot - 1]
					)
				local target = proto_at[a]
				clear_from(dependency_of, a)
				clear_from(is_import, a)
				clear_from(strings, a)
				clear_from(proto_at, a)

				if literal then dependency_of[a] = resolve_import_path(literal, importer) end

				if target then run(target) end
			elseif op == "KNIL" then
				for register = a, d do
					dependency_of[register] = nil
					is_import[register] = nil
					strings[register] = nil
					proto_at[register] = nil
				end
			elseif band(mode, 7) == 1 then
				dependency_of[a] = nil
				is_import[a] = nil
				strings[a] = nil
				proto_at[a] = nil

				if op == "GGET" then
					is_import[a] = funck(proto, -d - 1) == "import" or nil
				elseif op == "KSTR" then
					strings[a] = funck(proto, -d - 1)
				elseif op == "MOV" then
					dependency_of[a] = dependency_of[d]
					is_import[a] = is_import[d]
					strings[a] = strings[d]
					proto_at[a] = proto_at[d]
				elseif op == "FNEW" then
					local child = funck(proto, -d - 1)
					proto_at[a] = child
					local line = lines and lines[funcinfo(child).linedefined]
					local name = line and
						(
							line:match("local%s+function%s+([%w_]+)") or
							line:match("local%s+([%w_]+)%s*=%s*function")
						)

					if name then functions_by_name[name] = child end
				elseif op == "UGET" then
					local name = funcuvname(proto, d)
					dependency_of[a] = aliases[name]
					proto_at[a] = functions_by_name[name]
				end
			end
		end
	end

	run(chunk)
	return uses
end
