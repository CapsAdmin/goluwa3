--ANALYZE
local callstack = {}
local debug = _G.debug

do
	local prof = require("jit.profile")

	function callstack.traceback(msg--[[#: string | nil]])
		msg = msg or "stack traceback:\n"
		return msg .. prof.dumpstack("pl\n", 100)
	end

	function callstack.get_line(level--[[#: 1 .. inf]])
		level = level + 2
		local str = prof.dumpstack("pl\n", 100)--[[# as string]]
		local pos = 1

		for i = 1, level do
			local start, stop = str:find("\n", pos, true)

			if not start or not stop then break end

			if i == level then return str:sub(pos, start - 1) end

			pos = stop + 1
		end

		return nil
	end
end

do
	local util = require("jit.util")

	function callstack.get_func_path_line(func--[[#: AnyFunction]])
		local info = util.funcinfo(func)
		return info.source, info.linedefined
	end
end

do
	local vmdef = require("jit.vmdef")

	local function replace(id_str)
		local id = tonumber(id_str)

		if id and vmdef.ffnames[id] then return vmdef.ffnames[id] end

		return "[builtin#" .. id_str .. " (unknown id)]"
	end

	function callstack.format(callstack_str--[[#: string]])
		if not callstack_str or callstack_str == "" then return {} end

		callstack_str = callstack_str:gsub("%[builtin#(%d+)%]", replace)
		local lines = {}

		for _, line in ipairs(callstack_str:sub(1, -2):split("\n")) do
			table.insert(lines, line)
		end

		return lines
	end
end

function callstack.get_path_line(level--[[#: 1 .. inf]])
	local line = callstack.get_line(level + 1)

	if not line then return nil end

	local colon = line:find(":", nil, true)

	if not colon then return line end

	return line:sub(1, colon - 1), line:sub(colon + 1), line
end

do
	local ffi = require("ffi")
	ffi.cdef([[
		int backtrace (void **buffer, int size);
		char ** backtrace_symbols_fd(void *const *buffer, int size, int fd);
	]])

	function callstack.c_traceback()
		local max = 64
		local array = ffi.new("void *[?]", max)
		local size = ffi.C.backtrace(array, max)
		ffi.C.backtrace_symbols_fd(array, size, 1)
	end
end

local function on_error(msg)
	local sep = "\n  "
	local lines = callstack.format(callstack.traceback(""))

	if not lines[1] then return msg end

	return msg .. sep .. table.concat(lines, sep)
end

function callstack.pcall(func, ...)
	return xpcall(func, on_error, ...)
end

return callstack
