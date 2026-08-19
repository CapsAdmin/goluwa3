local love = import("lua/love.lua")
local W, H = 900, 600
local title = love.graphics.newQuad(0, 0, W, H, 1024, 1024)
local dog = love.graphics.newQuad(0, 32, 16, 16, 128, 128)
local coin = {}

for i = 0, 5 do
	coin[i] = love.graphics.newQuad(i * 16, 32, 13, 20, 128, 128)
end

local imgTitle = love.graphics.newImage("addons/love/games/sienna/art/titlescreen.png")
local imgObjects = love.graphics.newImage("addons/love/games/sienna/art/player2.png")
imgTitle:setFilter("nearest", "nearest")
--imgTitle:setWrap("repeat", "repeat")
imgTitle:getGoluwaTexture():Download():Save()
love.window.setMode(W, H)

function love.draw()
	love.graphics.scale(3, 3)
	love.graphics.drawq(imgTitle, title, 0, 0, 0, H / 2 / W)
	love.graphics.drawq(imgObjects, coin[math.ceil(os.clock() * 10 % 5)], 150, 100)
end
