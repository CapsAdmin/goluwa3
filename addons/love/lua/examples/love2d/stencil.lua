local bootstrap = import("lua/examples/love2d/_bootstrap.lua")
local love = bootstrap("love2d_stencil")

function love.draw()
	love.graphics.clear(0, 1, 0, 1)
	love.graphics.setBlendMode("replace")

	love.graphics.stencil(function()
		love.graphics.rectangle("fill", 0, 0, 32, 64)
	end)

	love.graphics.setStencilTest("greater", 0)
	love.graphics.setColor(1, 0, 0, 1)
	love.graphics.rectangle("fill", 0, 0, 64, 64)
	love.graphics.setStencilTest()
	love.graphics.setBlendMode("alpha")
	love.graphics.setColor(0, 0, 1, 1)
	love.graphics.rectangle("fill", 48, 0, 16, 64)
end
