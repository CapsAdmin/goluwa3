local bootstrap = assert(loadfile("game/addons/game/lua/examples/love2d/_bootstrap.lua"))()
local love = bootstrap("love2d_text_probe")
local font_small
local font_large
local text = "Sphinx of black quartz, judge my vow"
local wrap_text = "Wrapped text should stay inside the panel, honor alignment, and not inherit stale UV or texture state from earlier draws."
local time = 0

local function draw_panel(x, y, w, h)
	love.graphics.setColor(24, 28, 38, 255)
	love.graphics.rectangle("fill", x, y, w, h)
	love.graphics.setColor(110, 120, 146, 255)
	love.graphics.rectangle("line", x, y, w, h)
end

local function draw_crosshair(x, y)
	love.graphics.setColor(255, 180, 40, 255)
	love.graphics.line(x - 8, y, x + 8, y)
	love.graphics.line(x, y - 8, x, y + 8)
end

function love.load()
	font_small = love.graphics.newFont(18)
	font_large = love.graphics.newFont(42)
end

function love.update(dt)
	time = time + dt
end

function love.draw()
	local phase = math.sin(time * 1.25) * 28
	love.graphics.clear(14, 16, 22, 255)
	love.graphics.setColor(255, 255, 255, 255)
	love.graphics.print("love text probe", 28, 18)
	love.graphics.print(
		"Check baseline, rotation, wrapping, and whether text draws after textured panels.",
		28,
		40
	)
	draw_panel(28, 82, 250, 150)
	love.graphics.setFont(font_large)
	draw_crosshair(60, 132)
	love.graphics.setColor(235, 240, 245, 255)
	love.graphics.print("Hg", 60, 132)
	love.graphics.setColor(150, 210, 255, 255)
	love.graphics.print("baseline anchor", 60, 192)
	draw_panel(304, 82, 250, 150)
	love.graphics.setFont(font_small)
	love.graphics.setColor(255, 120, 90, 255)
	love.graphics.printf(wrap_text, 320, 98, 218, "left")
	love.graphics.setColor(120, 255, 160, 255)
	love.graphics.printf("centered", 320, 190, 218, "center")
	draw_panel(580, 82, 180, 150)
	love.graphics.setFont(font_large)
	love.graphics.push()
	love.graphics.translate(670, 156)
	love.graphics.rotate(0.25)
	love.graphics.setColor(255, 255, 255, 255)
	love.graphics.print("spin", phase, -20)
	love.graphics.pop()
	-- Draw a textured panel first, then text, to catch stale texture/UV state.
	love.graphics.setColor(60, 160, 255, 255)
	love.graphics.rectangle("fill", 28, 262, 732, 90)
	love.graphics.setColor(255, 255, 255, 255)
	love.graphics.setFont(font_small)
	love.graphics.print(text, 44, 294)
	love.graphics.setColor(200, 210, 224, 255)
	love.graphics.print("Expected:", 28, 382)
	love.graphics.print("1. 'Hg' sits on the crosshair without snapping wildly frame to frame", 28, 402)
	love.graphics.print("2. wrapped text stays inside its panel", 28, 422)
	love.graphics.print("3. rotated text stays legible and does not smear", 28, 442)
	love.graphics.print("4. the final line still renders after the blue filled panel", 28, 462)
end
