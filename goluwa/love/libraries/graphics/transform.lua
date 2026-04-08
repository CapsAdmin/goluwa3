local render2d = import("goluwa/render2d/render2d.lua")
local system = import("goluwa/system.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local frame = import("goluwa/love/libraries/graphics/frame.lua")
local shared = import("goluwa/love/libraries/graphics/shared.lua")
local love = ...

if type(love) == "string" then love = nil end

love = love or _G.love
local get_main_surface_dimensions = frame.Get(love).get_main_surface_dimensions
local ENV = shared.Get(love).ENV

local function get_graphics_dimensions()
	if ENV.graphics_current_canvas then return get_main_surface_dimensions() end

	if love.window and love.window.getMode then
		local width, height = love.window.getMode()

		if width and height and width > 0 and height > 0 then
			return width, height
		end
	end

	return get_main_surface_dimensions()
end

love.graphics.origin = render2d.LoadIdentity
love.graphics.translate = render2d.Translatef
love.graphics.shear = render2d.Shear
love.graphics.rotate = render2d.Rotate
love.graphics.push = render2d.PushMatrix
love.graphics.pop = render2d.PopMatrix

function love.graphics.scale(x, y)
	y = y or x
	render2d.Scalef(x, y)
end

function love.graphics.setCaption(title)
	system.GetWindow():SetTitle(title)
end

function love.graphics.getWidth()
	local width = get_graphics_dimensions()
	return width
end

function love.graphics.getHeight()
	local _, height = get_graphics_dimensions()
	return height
end

function love.graphics.setMode(width, height, fullscreen, vsync, fsaa)
	system.GetWindow():SetSize(Vec2(width, height))
	return true
end

function love.graphics.getMode()
	local size = system.GetWindow():GetSize()
	return size.x, size.y, false, false, false
end

function love.graphics.getDimensions()
	return get_graphics_dimensions()
end

function love.graphics.getDPIScale()
	if love.window and love.window.getDPIScale then
		return love.window.getDPIScale()
	end

	if love.window and love.window.getPixelScale then
		return love.window.getPixelScale()
	end

	return 1
end

return love.graphics
