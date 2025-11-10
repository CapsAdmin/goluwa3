local ffi = require("ffi")
local T = {}
local fixed_len_cache = {}
local var_len_cache = {}

local function array_type(t, len)
	local key = tonumber(t)

	if len then
		fixed_len_cache[key] = fixed_len_cache[key] or ffi.typeof("$[" .. len .. "]", t)
		return fixed_len_cache[key]
	end

	var_len_cache[key] = var_len_cache[key] or ffi.typeof("$[?]", t)
	return var_len_cache[key]
end

function T.Array(t, len, ctor)
	if ctor then return array_type(t, len)(ctor) end

	return array_type(t, len)
end

function T.Box(t, ctor)
	if ctor then return array_type(t, 1)({ctor}) end

	return array_type(t, 1)
end

return T
