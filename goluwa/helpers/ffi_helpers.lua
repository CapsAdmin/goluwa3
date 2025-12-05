local ffi = require("ffi")
local ffi_helpers = {}

function ffi_helpers.get_enums(enum_type)
	local out = {}
	local enum_id = tonumber(ffi.typeof(enum_type))
	local enum_ctype = ffi.typeinfo(enum_id)
	local sib = enum_ctype.sib

	while sib do
		local sib_ctype = ffi.typeinfo(sib)
		local CT_code = bit.rshift(sib_ctype.info, 28)
		local current_index = sib_ctype.size

		-- bug?
		if current_index == nil then current_index = -1 end

		if CT_code == 11 then out[sib_ctype.name] = current_index end

		sib = sib_ctype.sib
	end

	return out
end

function ffi_helpers.enum_to_string(enum_type, enum)
	if not enum then enum = enum_type end

	local enums = ffi_helpers.get_enums(enum_type)

	for name, value in pairs(enums) do
		if value == tonumber(enum) then return name end
	end

	return "UNKNOWN_ENUM_VALUE"
end

function ffi_helpers.bit_enums_to_table(enum_type, flags)
	local enums = ffi_helpers.get_enums(enum_type)
	local out = {}

	for name, value in pairs(enums) do
		if bit.band(flags, value) ~= 0 then table.insert(out, name) end
	end

	return out
end

do
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

	function ffi_helpers.Array(t, len, ctor)
		if ctor then return array_type(t, len)(ctor) end

		return array_type(t, len)
	end

	function ffi_helpers.Box(t, ctor)
		if ctor then return array_type(t, 1)({ctor}) end

		return array_type(t, 1)
	end
end

return ffi_helpers
