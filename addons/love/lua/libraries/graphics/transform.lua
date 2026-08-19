local render2d = import("goluwa/render2d/render2d.lua")
local render = import("goluwa/render/render.lua")
local system = import("goluwa/system.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local shared = import("addons/love/lua/libraries/graphics/shared.lua")
local love = ...

if type(love) == "string" then love = nil end

love = love or import("lua/love.lua")
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
	return render.GetWidth()
end

function love.graphics.getHeight()
	return render.GetHeight()
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
	return render.GetRenderImageSize():Unpack()
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
