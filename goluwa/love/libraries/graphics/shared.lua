local render = import("goluwa/render/render.lua")
local Framebuffer = import("goluwa/render/framebuffer.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local math2d = import("goluwa/render2d/math2d.lua")
local vfs = import("goluwa/vfs.lua")
local gfx = import("goluwa/render2d/gfx.lua")
local fonts = import("goluwa/render2d/fonts.lua")
local window = import("goluwa/window.lua")
local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
local RenderMesh = import("goluwa/render/mesh.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local IndexBuffer = import("goluwa/render/index_buffer.lua")
local line = import("goluwa/love/line.lua")
local love = ... or _G.love
local ENV = love._line_env
ENV.textures = ENV.textures or table.weak(true)
ENV.graphics_filter_min = ENV.graphics_filter_min or "linear"
ENV.graphics_filter_mag = ENV.graphics_filter_mag or "linear"
ENV.graphics_filter_anisotropy = ENV.graphics_filter_anisotropy or 1
love.graphics = love.graphics or {}

local function love_uses_normalized_color_range()
	return (love._version_major or 0) >= 11
end

local function get_api_default_alpha()
	if love_uses_normalized_color_range() then return 1 end

	return 255
end

local function color_component_to_internal(value)
	value = value or 0

	if love_uses_normalized_color_range() and value >= 0 and value <= 1 then
		return value * 255
	end

	return value
end

local function color_component_from_internal(value)
	value = value or 0

	if love_uses_normalized_color_range() then return value / 255 end

	return value
end

local function parse_color_bytes(r, g, b, a, default_a)
	if type(r) == "table" then
		return parse_color_bytes(r[1], r[2], r[3], r[4], default_a)
	end

	if a == nil then a = default_a or get_api_default_alpha() end

	return color_component_to_internal(r or 0),
	color_component_to_internal(g or 0),
	color_component_to_internal(b or 0),
	color_component_to_internal(a)
end

local function get_internal_color()
	return ENV.graphics_color_r or 255,
	ENV.graphics_color_g or 255,
	ENV.graphics_color_b or 255,
	ENV.graphics_color_a or 255
end

local function get_internal_background_color()
	return ENV.graphics_bg_color_r or 0,
	ENV.graphics_bg_color_g or 0,
	ENV.graphics_bg_color_b or 0,
	ENV.graphics_bg_color_a or 255
end

local function translate_wrap_mode(mode)
	if mode == "clamp" then return "clamp_to_edge" end

	if mode == "clampzero" then
		return "clamp_to_border", "float_transparent_black"
	end

	return mode
end

local function ADD_FILTER(obj)
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

return {
	love = love,
	ENV = ENV,
	render = render,
	Framebuffer = Framebuffer,
	render2d = render2d,
	math2d = math2d,
	vfs = vfs,
	gfx = gfx,
	fonts = fonts,
	window = window,
	EasyPipeline = EasyPipeline,
	RenderMesh = RenderMesh,
	Vec2 = Vec2,
	IndexBuffer = IndexBuffer,
	line = line,
	love_uses_normalized_color_range = love_uses_normalized_color_range,
	get_api_default_alpha = get_api_default_alpha,
	color_component_to_internal = color_component_to_internal,
	color_component_from_internal = color_component_from_internal,
	parse_color_bytes = parse_color_bytes,
	get_internal_color = get_internal_color,
	get_internal_background_color = get_internal_background_color,
	translate_wrap_mode = translate_wrap_mode,
	ADD_FILTER = ADD_FILTER,
}
