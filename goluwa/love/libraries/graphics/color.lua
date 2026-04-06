local render = import("goluwa/render/render.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local shared = import("goluwa/love/libraries/graphics/shared.lua")
local frame = import("goluwa/love/libraries/graphics/frame.lua")
local love = ...

if type(love) == "string" then love = nil end

love = love or _G.love
local ctx = shared.Get(love)
local ENV = ctx.ENV
local parse_color_bytes = ctx.parse_color_bytes
local get_api_default_alpha = ctx.get_api_default_alpha
local color_component_from_internal = ctx.color_component_from_internal
local get_internal_background_color = ctx.get_internal_background_color
local frame_ctx = frame.Get(love)
local clear_active_target = frame_ctx.clear_active_target
local draw_clear_rect = frame_ctx.draw_clear_rect
local mark_depth_target_initialized = frame_ctx.mark_depth_target_initialized
ENV.graphics_color_r = 255
ENV.graphics_color_g = 255
ENV.graphics_color_b = 255
ENV.graphics_color_a = 255

function love.graphics.setColor(r, g, b, a)
	ENV.graphics_color_r, ENV.graphics_color_g, ENV.graphics_color_b, ENV.graphics_color_a = parse_color_bytes(r, g, b, a, get_api_default_alpha())
	render2d.SetColor(
		ENV.graphics_color_r / 255,
		ENV.graphics_color_g / 255,
		ENV.graphics_color_b / 255,
		ENV.graphics_color_a / 255
	)
end

function love.graphics.getColor()
	return color_component_from_internal(ENV.graphics_color_r),
	color_component_from_internal(ENV.graphics_color_g),
	color_component_from_internal(ENV.graphics_color_b),
	color_component_from_internal(ENV.graphics_color_a)
end

ENV.graphics_bg_color_r = 0
ENV.graphics_bg_color_g = 0
ENV.graphics_bg_color_b = 0
ENV.graphics_bg_color_a = 255

function love.graphics.setBackgroundColor(r, g, b, a)
	ENV.graphics_bg_color_r, ENV.graphics_bg_color_g, ENV.graphics_bg_color_b, ENV.graphics_bg_color_a = parse_color_bytes(r, g, b, a, 255)
end

function love.graphics.getBackgroundColor()
	return color_component_from_internal(ENV.graphics_bg_color_r),
	color_component_from_internal(ENV.graphics_bg_color_g),
	color_component_from_internal(ENV.graphics_bg_color_b),
	color_component_from_internal(ENV.graphics_bg_color_a)
end

function love.graphics.clear(r, g, b, a, ...)
	local canvas = love.graphics.getCanvas()
	local stencil
	local depth

	if select("#", ...) >= 1 then stencil = select(1, ...) end

	if select("#", ...) >= 2 then depth = select(2, ...) end

	if canvas then
		canvas:clear(r, g, b, a, stencil, depth)
	else
		local cr, cg, cb, ca

		if r ~= nil then
			cr, cg, cb, ca = parse_color_bytes(r, g, b, a, 255)
		else
			cr, cg, cb, ca = get_internal_background_color()
		end

		if not clear_active_target(cr, cg, cb, ca, depth, stencil) then
			draw_clear_rect(cr, cg, cb, ca, render.GetWidth(), render.GetHeight())
		end

		if depth ~= nil then
			local frame = render.GetCurrentFrame and render.GetCurrentFrame() or nil

			if frame ~= nil then mark_depth_target_initialized(frame) end
		end
	end
end

return love.graphics
