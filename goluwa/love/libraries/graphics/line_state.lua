local shared = import("goluwa/love/libraries/graphics/shared.lua")
local love = ...

if type(love) == "string" then love = nil end

love = love or _G.love
local ENV = shared.Get(love).ENV
ENV.graphics_line_width = 1
ENV.graphics_line_style = "rough"
ENV.graphics_line_join = "miter"

function love.graphics.setLineStyle(s)
	ENV.graphics_line_style = s
end

function love.graphics.getLineStyle()
	return ENV.graphics_line_style
end

function love.graphics.setLineJoin(s)
	ENV.graphics_line_join = s
end

function love.graphics.getLineJoin(s)
	return ENV.graphics_line_join
end

function love.graphics.setLineWidth(w)
	ENV.graphics_line_width = w
end

function love.graphics.getLineWidth()
	return ENV.graphics_line_width
end

function love.graphics.setLine(w, s)
	love.graphics.setLineWidth(w)
	love.graphics.setLineStyle(s)
end

return love.graphics
