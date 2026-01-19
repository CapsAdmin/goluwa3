local event = require("event")
local fonts = require("render2d.fonts")
local render2d = require("render2d.render2d")
local gfx = require("render2d.gfx")
local utf8 = require("utf8")
local fontSize = 256
local fontPath = fonts.GetSystemDefaultFont()
local font = fonts.LoadFont(fontPath, fontSize)
local labelFont = fonts.LoadFont(fontPath, 10)
local font2 = fonts.LoadFont(fontPath, 30)

local function drawArrow(x1, y1, x2, y2, size)
	size = size or 10
	local dx, dy = x2 - x1, y2 - y1
	local angle = math.atan2(dy, dx)
	gfx.DrawLine(x1, y1, x2, y2, 2)
	gfx.DrawLine(x2, y2, x2 - size * math.cos(angle - 0.5), y2 - size * math.sin(angle - 0.5), 2)
	gfx.DrawLine(x2, y2, x2 - size * math.cos(angle + 0.5), y2 - size * math.sin(angle + 0.5), 2)
end

local function drawDoubleArrow(x1, y1, x2, y2, size)
	drawArrow(x1, y1, x2, y2, size)
	drawArrow(x2, y2, x1, y1, size)
end

event.AddListener("Draw2D", "fonts_metrics_diagram", function()
	render2d.SetColor(1, 1, 1, 1)
	render2d.SetTexture(nil)
	render2d.DrawRect(0, 0, render2d.GetSize())
	local sw, sh = render2d.GetSize()
	local ox, oy = sw * 0.3, sh * 0.4
	local char = "g"
	local char_code = utf8.uint32(char)
	local data = font:GetChar(char_code)

	if not data then return end

	local ascent = font:GetAscent()
	-- Standard metrics
	local xMin, xMax = data.x_min, data.x_max
	local yMin, yMax = data.y_min, data.y_max
	local advance = data.x_advance
	local bearingX = data.bearing_x
	local bearingY = data.bearing_y
	local width = xMax - xMin
	local height = yMax - yMin
	-- 1. Draw Axes
	render2d.SetColor(0.3, 0.3, 0.3, 1)
	gfx.DrawLine(ox - 100, oy, ox + advance + 100, oy, 2) -- Baseline
	gfx.DrawLine(ox, oy - 150, ox, oy + ascent + 50, 2) -- Vertical axis
	-- 2. Draw Origin
	render2d.SetColor(0, 0, 0, 1)
	gfx.DrawFilledCircle(ox, oy, 5)
	labelFont:DrawText("(0,0)", ox - 45, oy - 25)
	-- 3. Draw Character
	render2d.SetColor(0, 0, 0, 1)
	-- Using the new "baseline" alignment support!
	font:DrawText(char, ox, oy, 0, 0, "baseline")
	-- 4. Bounding Box
	-- In TTF, Y increases UPWARDS. In our renderer, Y increases DOWNWARDS.
	-- So a point at yMin (e.g. -50) is visually oy - (-50) = oy + 50.
	-- A point at yMax (e.g. 150) is visually oy - (150) = oy - 150.
	render2d.SetColor(0.8, 0.2, 0.2, 0.4)
	local vyMin, vyMax = oy - yMin, oy - yMax
	gfx.DrawLine(ox + xMin, vyMin, ox + xMax, vyMin, 1)
	gfx.DrawLine(ox + xMin, vyMax, ox + xMax, vyMax, 1)
	gfx.DrawLine(ox + xMin, vyMin, ox + xMin, vyMax, 1)
	gfx.DrawLine(ox + xMax, vyMin, ox + xMax, vyMax, 1)
	-- 5. Metrics Labels and Arrows
	-- width
	render2d.SetColor(0.2, 0.6, 0.2, 1)
	drawDoubleArrow(ox + xMin, vyMax - 20, ox + xMax, vyMax - 20)
	labelFont:DrawText("width", ox + (xMin + xMax) / 2 - 20, vyMax - 25)
	-- height
	render2d.SetColor(0.2, 0.2, 0.7, 1)
	drawDoubleArrow(ox + xMax + 20, vyMin, ox + xMax + 20, vyMax)
	labelFont:DrawText("height", ox + xMax + 25, (vyMin + vyMax) / 2 - 5)
	-- bearingX
	render2d.SetColor(0.7, 0.4, 0, 1)
	drawArrow(ox, (vyMin + vyMax) / 2, ox + xMin, (vyMin + vyMax) / 2)
	labelFont:DrawText("bearingX", ox + xMin / 2 - 30, (vyMin + vyMax) / 2 + 10)
	-- bearingY
	render2d.SetColor(0.5, 0, 0.5, 1)
	drawArrow(ox + (xMin + xMax) / 2, oy, ox + (xMin + xMax) / 2, vyMax)
	labelFont:DrawText("bearingY", ox + (xMin + xMax) / 2 + 5, (oy + vyMax) / 2)
	-- advance
	render2d.SetColor(0, 0.5, 0.5, 1)
	drawArrow(ox, oy - 120, ox + advance, oy - 120)
	labelFont:DrawText("advance", ox + advance / 2 - 20, oy - 145)
	gfx.DrawLine(ox + advance, oy - 10, ox + advance, oy + 10, 2)
	gfx.DrawFilledCircle(ox + advance, oy, 4)
	-- xMin, xMax, yMin, yMax (markers)
	render2d.SetColor(0.4, 0.4, 0.4, 1)
	gfx.DrawLine(ox + xMin, vyMax, ox + xMin, vyMax - 60, 1)
	labelFont:DrawText("xMin", ox + xMin - 15, vyMax - 65)
	gfx.DrawLine(ox + xMax, vyMax, ox + xMax, vyMax - 60, 1)
	labelFont:DrawText("xMax", ox + xMax - 15, vyMax - 65)
	gfx.DrawLine(ox + xMax, vyMax, ox + xMax + 60, vyMax, 1)
	labelFont:DrawText("yMax", ox + xMax + 65, vyMax - 5)
	gfx.DrawLine(ox + xMax, vyMin, ox + xMax + 60, vyMin, 1)
	labelFont:DrawText("yMin", ox + xMax + 65, vyMin - 5)

	do
		local text = [[Whereas a common understanding of these rights and freedoms is]]
		local baseline = 512
		local x, y = gfx.GetMousePosition()
		local str = font2:WrapString(text, x + 10)
		str = "hello\nworldddd"
		local w, h = font2:GetTextSize(str)
		render2d.SetTexture(nil)
		render2d.SetColor(1, 0, 0, 0.25)
		render2d.DrawRect(0, 0, w, h)

		do
			render2d.SetColor(0, 0, 0, 1)
			font2:DrawText(str, 0, 0)
		end
	end
end)
