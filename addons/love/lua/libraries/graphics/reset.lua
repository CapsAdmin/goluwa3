local love = ...

if type(love) == "string" then love = nil end

love = love or _G.love

function love.graphics.reset()
	love.graphics.setColor(255, 255, 255, 255)
	love.graphics.setBackgroundColor(0, 0, 0, 255)
	love.graphics.setCanvas()
	love.graphics.setShader()
	love.graphics.origin()
	love.graphics.setBlendMode("alpha")
	love.graphics.setLine(1, "smooth")
	love.graphics.setPoint(1, "smooth")
end

return love.graphics
