local ffi = require("ffi")

local function get_enums(enum_type)
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

local function build_translator(ctype, starts_with, strip)
	local enums = get_enums(ctype)
	local translate = {}
	local friendly_translate = {}
	local friendly_translate_rev = {}

	for enum, num in pairs(enums) do
		if enum:sub(1, #starts_with) == starts_with then
			local friendly = enum
			friendly = friendly:sub(#starts_with + 1)

			if strip then
				for _, s in ipairs(strip) do
					friendly = friendly:gsub(s, "")
				end
			end

			translate[friendly:lower()] = num
			friendly_translate[friendly:lower()] = num
			friendly_translate_rev[num] = friendly:lower()
		end

		translate[enum:lower()] = num
	end

	local function to_enum(str)
		str = str:lower()

		if not translate[str] then error("invalid enum: " .. str, 2) end

		return translate[str]
	end

	local function translate(str)
		if type(str) == "table" then
			local out = 0

			for _, flag in ipairs(str) do
				out = bit.bor(out, to_enum(flag))
			end

			return out
		end

		return to_enum(str)
	end

	return setmetatable(
		{
			to_string = function(enum)
				enum = tonumber(enum)

				if not friendly_translate_rev[enum] then
					for k, v in pairs(friendly_translate_rev) do
						print(k, v)
					end

					error("invalid enum: " .. tostring(enum), 2)
				end

				return friendly_translate_rev[enum]
			end,
		},
		{
			__call = function(_, str)
				return translate(str)
			end,
		}
	)
end

local function enum_to_string(enum_type, enum)
	if not enum then enum = enum_type end

	local enums = get_enums(enum_type)

	for name, value in pairs(enums) do
		if value == tonumber(enum) then return name end
	end

	return "UNKNOWN_ENUM_VALUE"
end

return {
	enum_to_string = enum_to_string,
	build_translator = build_translator,
}
