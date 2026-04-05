local render2d = import("goluwa/render2d/render2d.lua")
local window = import("goluwa/window.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
return function(ctx)
	local love = ctx.love
	local get_main_surface_dimensions = ctx.get_main_surface_dimensions
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
		window.SetTitle(title)
	end

	function love.graphics.getWidth()
		local width = get_main_surface_dimensions()
		return width
	end

	function love.graphics.getHeight()
		local _, height = get_main_surface_dimensions()
		return height
	end

	function love.graphics.setMode(width, height, fullscreen, vsync, fsaa)
		window.SetSize(Vec2(width, height))
		return true
	end

	function love.graphics.getMode()
		return window.GetSize().x, window.GetSize().y, false, false, false
	end

	function love.graphics.getDimensions()
		return get_main_surface_dimensions()
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
end
