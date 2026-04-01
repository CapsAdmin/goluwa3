local bootstrap = assert(loadfile("game/addons/game/lua/examples/love2d/_bootstrap.lua"))()
local love = bootstrap("love2d_subpixel_probe")
local sprite
local time = 0

local function make_sprite()
	local data = love.image.newImageData(24, 24)

	for y = 0, 23 do
		for x = 0, 23 do
			local alpha = (x > 2 and x < 21 and y > 2 and y < 21) and 255 or 0
			data:setPixel(x, y, 255, 180, 36, alpha)
		end
	end

	for i = 0, 23 do
		data:setPixel(i, 12, 255, 255, 255, 255)
		data:setPixel(12, i, 255, 255, 255, 255)
	end

	sprite = love.graphics.newImage(data)
end

function love.load()
	make_sprite()
end

function love.update(dt)
	time = time + dt
end

function love.draw()
	local x = 64 + math.sin(time * 1.3) * 42.5
	local y = 128 + math.cos(time * 1.7) * 28.25
	local x2 = 420 + math.sin(time * 0.9) * 36.75
	local y2 = 196 + math.cos(time * 1.2) * 22.5
	love.graphics.clear(13, 15, 21, 255)
	love.graphics.setColor(255, 255, 255, 255)
	love.graphics.print("subpixel transform probe", 28, 18)
	love.graphics.print(
		"The moving sprites should glide smoothly across the grid without obvious 1px snapping.",
		28,
		40
	)

	for i = 0, 10 do
		local gx = 32 + i * 48
		love.graphics.setColor(55, 62, 78, 255)
		love.graphics.line(gx, 88, gx, 360)
	end

	for i = 0, 5 do
		local gy = 88 + i * 48
		love.graphics.setColor(55, 62, 78, 255)
		love.graphics.line(32, gy, 736, gy)
	end

	love.graphics.setColor(255, 255, 255, 255)
	love.graphics.print(string.format("image draw: x=%.2f y=%.2f", x, y), 32, 88)
	love.graphics.draw(sprite, x, y, time * 0.25, 2.5, 2.5, 12, 12)
	love.graphics.print(string.format("translate/draw: x=%.2f y=%.2f", x2, y2), 380, 88)
	love.graphics.push()
	love.graphics.translate(x2, y2)
	love.graphics.rotate(-time * 0.4)
	love.graphics.draw(sprite, 0, 0, 0, 3, 3, 12, 12)
	love.graphics.pop()
	love.graphics.setColor(210, 220, 235, 255)
	love.graphics.print(
		"If the left sprite jitters, inspect love.graphics.draw and DrawRectf usage.",
		32,
		386
	)
	love.graphics.print(
		"If the right sprite jitters more, inspect love.graphics.translate/scale aliases and matrix rounding.",
		32,
		406
	)
end
