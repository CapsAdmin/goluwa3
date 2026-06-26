local render = import("goluwa/render/render.lua")
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

	do
		ENV.graphics_color_r = 1
		ENV.graphics_color_g = 1
		ENV.graphics_color_b = 1
		ENV.graphics_color_a = 1

		function ctx.set_fg_color(r, g, b, a)
			ENV.graphics_color_r, ENV.graphics_color_g, ENV.graphics_color_b, ENV.graphics_color_a = ctx.color_to_engine(r, g, b, a)
		end

		function ctx.get_fg_color()
			if ctx.love_uses_normalized_color_range() then
				return ENV.graphics_color_r,
				ENV.graphics_color_g,
				ENV.graphics_color_b,
				ENV.graphics_color_a
			end

			return math.floor(ENV.graphics_color_r * 255 + 0.5),
			math.floor(ENV.graphics_color_g * 255 + 0.5),
			math.floor(ENV.graphics_color_b * 255 + 0.5),
			math.floor(ENV.graphics_color_a * 255 + 0.5)
		end
	end

	do
		ENV.graphics_bg_color_r = 0
		ENV.graphics_bg_color_g = 0
		ENV.graphics_bg_color_b = 0
		ENV.graphics_bg_color_a = 1

		function ctx.set_bg_color(r, g, b, a)
			ENV.graphics_bg_color_r, ENV.graphics_bg_color_g, ENV.graphics_bg_color_b, ENV.graphics_bg_color_a = ctx.color_to_engine(r, g, b, a)
		end

		function ctx.get_bg_color()
			if ctx.love_uses_normalized_color_range() then
				return ENV.graphics_bg_color_r,
				ENV.graphics_bg_color_g,
				ENV.graphics_bg_color_b,
				ENV.graphics_bg_color_a
			end

			return math.floor(ENV.graphics_bg_color_r * 255 + 0.5),
			math.floor(ENV.graphics_bg_color_g * 255 + 0.5),
			math.floor(ENV.graphics_bg_color_b * 255 + 0.5),
			math.floor(ENV.graphics_bg_color_a * 255 + 0.5)
		end
	end

	function ctx.love_uses_normalized_color_range()
		return love._version_major >= 11
	end

	local function normalize_color_component(value, default)
		if value == nil then return default or 0 end

		if ctx.love_uses_normalized_color_range() then return value end

		-- Love < 0.11: input is 0-255, normalize to 0-1
		return math.min(value / 255, 1)
	end

	function ctx.mesh_vertex_color_to_engine(color)
		color[1] = normalize_color_component(color[1])
		color[2] = normalize_color_component(color[2])
		color[3] = normalize_color_component(color[3])
		color[4] = normalize_color_component(color[4], 1)
	end

	function ctx.color_to_engine(r, g, b, a)
		if type(r) == "table" then
			return ctx.color_to_engine(r[1], r[2], r[3], r[4])
		end

		return normalize_color_component(r),
		normalize_color_component(g),
		normalize_color_component(b),
		normalize_color_component(a, 1)
	end

	function ctx.get_draw_fg_color(r, g, b, a)
		if not r then
			r, g, b, a = ENV.graphics_color_r or 1,
			ENV.graphics_color_g or 1,
			ENV.graphics_color_b or 1,
			ENV.graphics_color_a or 1
		end

		return r, g, b, a or 1
	end

	function ctx.get_draw_bg_color(r, g, b, a)
		if not r then
			r, g, b, a = ENV.graphics_bg_color_r or 0,
			ENV.graphics_bg_color_g or 0,
			ENV.graphics_bg_color_b or 0,
			ENV.graphics_bg_color_a or 1
		end

		return r, g, b, a or 1
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

	function ctx.get_main_surface_dimensions()
		if ENV.graphics_current_canvas then
			return ENV.graphics_current_canvas:getDimensions()
		end

		return render.GetRenderImageSize():Unpack()
	end

	cache[love] = ctx
	return ctx
end

function M.Get(love)
	return cache[love] or create(love)
end

return M
