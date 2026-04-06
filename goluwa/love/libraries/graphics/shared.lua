local M = {}
local cache = setmetatable({}, {__mode = "k"})

local function create(love)
	assert(type(love) == "table" and love._line_env, "graphics shared requires a love env")
	local ENV = love._line_env
	ENV.textures = ENV.textures or table.weak(true)
	ENV.graphics_filter_min = ENV.graphics_filter_min or "linear"
	ENV.graphics_filter_mag = ENV.graphics_filter_mag or "linear"
	ENV.graphics_filter_anisotropy = ENV.graphics_filter_anisotropy or 1
	love.graphics = love.graphics or {}
	local ctx = {
		love = love,
		ENV = ENV,
	}

	function ctx.love_uses_normalized_color_range()
		return (love._version_major or 0) >= 11
	end

	function ctx.get_api_default_alpha()
		if ctx.love_uses_normalized_color_range() then return 1 end

		return 255
	end

	function ctx.color_component_to_internal(value)
		value = value or 0

		if ctx.love_uses_normalized_color_range() and value >= 0 and value <= 1 then
			return value * 255
		end

		return value
	end

	function ctx.color_component_from_internal(value)
		value = value or 0

		if ctx.love_uses_normalized_color_range() then return value / 255 end

		return value
	end

	function ctx.parse_color_bytes(r, g, b, a, default_a)
		if type(r) == "table" then
			return ctx.parse_color_bytes(r[1], r[2], r[3], r[4], default_a)
		end

		if a == nil then a = default_a or ctx.get_api_default_alpha() end

		return ctx.color_component_to_internal(r or 0),
		ctx.color_component_to_internal(g or 0),
		ctx.color_component_to_internal(b or 0),
		ctx.color_component_to_internal(a)
	end

	function ctx.get_internal_color()
		return ENV.graphics_color_r or 255,
		ENV.graphics_color_g or 255,
		ENV.graphics_color_b or 255,
		ENV.graphics_color_a or 255
	end

	function ctx.get_internal_background_color()
		return ENV.graphics_bg_color_r or 0,
		ENV.graphics_bg_color_g or 0,
		ENV.graphics_bg_color_b or 0,
		ENV.graphics_bg_color_a or 255
	end

	function ctx.translate_wrap_mode(mode)
		if mode == "clamp" then return "clamp_to_edge" end

		if mode == "clampzero" then
			return "clamp_to_border", "float_transparent_black"
		end

		return mode
	end

	function ctx.ADD_FILTER(obj)
		obj.setFilter = function(s, min, mag, anistropy)
			s.filter_min = min or s.filter_min or ENV.graphics_filter_min
			s.filter_mag = mag or min or s.filter_mag or ENV.graphics_filter_mag
			s.filter_anistropy = anistropy or s.filter_anistropy or ENV.graphics_filter_anisotropy
			local tex = ENV.textures[s]

			if not tex then return end

			tex:SetMinFilter(s.filter_min)
			tex:SetMagFilter(s.filter_mag)
			tex:SetAnisotropy(s.filter_anistropy)
		end
		obj.getFilter = function(s)
			return s.filter_min, s.filter_mag, s.filter_anistropy
		end
	end

	cache[love] = ctx
	return ctx
end

function M.Get(love)
	return cache[love] or create(love)
end

return M
