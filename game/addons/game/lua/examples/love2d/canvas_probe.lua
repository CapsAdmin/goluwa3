local bootstrap = assert(loadfile("game/addons/game/lua/examples/love2d/_bootstrap.lua"))()
local love = bootstrap("love2d_canvas_probe")
local canvas
local checker
local quad

local function build_checker_image()
	local data = love.image.newImageData(48, 48)

	for y = 0, 47 do
		for x = 0, 47 do
			if x < 24 then
				data:setPixel(x, y, 26, 158, 235, 255)
			else
				data:setPixel(x, y, 235, 60, 78, 255)
			end
		end
	end

	for i = 0, 47 do
		data:setPixel(i, i, 255, 255, 255, 255)
		data:setPixel(47 - i, i, 255, 215, 0, 255)
	end

	checker = love.graphics.newImage(data)
	quad = love.graphics.newQuad(0, 0, 24, 24, 48, 48)
end

function love.load()
	canvas = love.graphics.newCanvas(144, 144)
	build_checker_image()
	canvas:setFilter("nearest", "nearest", 1)
	checker:setFilter("nearest", "nearest", 1)
end

function love.draw()
	love.graphics.clear(16, 20, 28, 255)
	love.graphics.setColor(255, 255, 255, 255)
	love.graphics.print("canvas clear + canvas sampling probe", 28, 18)
	love.graphics.print(
		"The canvas tile should match the direct image orientation and keep transparent corners.",
		28,
		40
	)

	canvas:renderTo(function()
		love.graphics.clear(0, 0, 0, 0)
		love.graphics.setColor(255, 255, 255, 255)
		love.graphics.draw(checker, 16, 16, 0, 2, 2)
		love.graphics.setColor(255, 255, 255, 180)
		love.graphics.rectangle("line", 8, 8, 128, 128)
		love.graphics.setColor(255, 140, 70, 210)
		love.graphics.rectangle("fill", 92, 92, 32, 32)
	end)

	love.graphics.setColor(255, 255, 255, 255)
	love.graphics.print("canvas", 32, 74)
	love.graphics.print("direct image", 236, 74)
	love.graphics.print("quad", 442, 74)
	love.graphics.draw(canvas, 28, 102)
	love.graphics.draw(checker, 236, 102, 0, 3, 3)
	love.graphics.draw(checker, quad, 442, 102, 0, 6, 6)
	love.graphics.setColor(210, 220, 235, 255)
	love.graphics.print("Expected:", 28, 276)
	love.graphics.print("1. canvas and direct image show the same diagonal orientation", 28, 296)
	love.graphics.print("2. the canvas corners stay transparent over the dark background", 28, 316)
	love.graphics.print("3. the quad shows the top-left quadrant, not a flipped one", 28, 336)
end
