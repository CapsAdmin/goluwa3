local love = import("lua/love.lua")
local W, H = 900, 600
local title = love.graphics.newQuad(0, 0, W, H, 1024, 1024)
local imgTitle = love.graphics.newImage("addons/love/games/sienna/art/titlescreen.png")
imgTitle:setFilter("linear", "linear")
love.window.setMode(W, H)

function love.draw()
	love.graphics.scale(3, 3)
	love.graphics.draw(imgTitle, title, 0, 0, 0, 300 / W)
end
