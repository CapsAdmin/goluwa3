local render2d = import("goluwa/render2d/render2d.lua")
local gfx = import("goluwa/render2d/gfx.lua")
return function(ctx)
	local love = ctx.love
	local SIZE = 1
	local STYLE = "rough"

	function love.graphics.setPointStyle(style)
		STYLE = style
	end

	function love.graphics.getPointStyle()
		return STYLE
	end

	function love.graphics.setPointSize(size)
		SIZE = size
	end

	function love.graphics.getPointSize()
		return SIZE
	end

	function love.graphics.setPoint(size, style)
		love.graphics.setPointSize(size)
		love.graphics.setPointStyle(style)
	end

	function love.graphics.point(x, y)
		if STYLE == "rough" then
			render2d.PushTexture()
			render2d.DrawRect(x, y, SIZE, SIZE, nil, SIZE / 2, SIZE / 2)
			render2d.PopTexture()
		else
			gfx.DrawFilledCircle(x, y, SIZE)
		end
	end

	function love.graphics.points(...)
		local points = ...

		if type(points) == "number" then points = {...} end

		if type(points[1]) == "number" then
			for i = 1, #points, 2 do
				love.graphics.point(points[i + 0], points[i + 1])
			end
		else
			for _, point in ipairs(points) do
				if point[3] then
					render2d.SetColor(
						(point[3] or 255) / 255,
						(point[4] or 255) / 255,
						(point[5] or 255) / 255,
						(point[6] or 255) / 255
					)
				end

				love.graphics.point(point[1], point[2])
			end
		end
	end
end
