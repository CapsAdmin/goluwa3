local event = require("event")
local fonts = require("render2d.fonts")
local render2d = require("render2d.render2d")
local gfx = require("render2d.gfx")
local utf8 = require("utf8")
local fontSize = 256
local fontPath = "/home/caps/Downloads/Roboto/static/Roboto-Regular.ttf"
local font = fonts.LoadFont(fontPath, fontSize)
local labelFont = fonts.LoadFont(fontPath, 10)

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
	-- We want baseline at oy. DrawText(x, y) uses y as top (oy + ascent)
	font:DrawText(char, ox, oy + ascent)
	-- 4. Bounding Box
	render2d.SetColor(0.8, 0.2, 0.2, 0.4)
	gfx.DrawLine(ox + xMin, oy + yMin, ox + xMax, oy + yMin, 1)
	gfx.DrawLine(ox + xMin, oy + yMax, ox + xMax, oy + yMax, 1)
	gfx.DrawLine(ox + xMin, oy + yMin, ox + xMin, oy + yMax, 1)
	gfx.DrawLine(ox + xMax, oy + yMin, ox + xMax, oy + yMax, 1)
	-- 5. Metrics Labels and Arrows
	-- width
	render2d.SetColor(0.2, 0.6, 0.2, 1)
	drawDoubleArrow(ox + xMin, oy + yMax + 20, ox + xMax, oy + yMax + 20)
	labelFont:DrawText("width", ox + (xMin + xMax) / 2 - 20, oy + yMax + 25)
	-- height
	render2d.SetColor(0.2, 0.2, 0.7, 1)
	drawDoubleArrow(ox + xMax + 20, oy + yMin, ox + xMax + 20, oy + yMax)
	labelFont:DrawText("height", ox + xMax + 25, oy + (yMin + yMax) / 2 - 5)
	-- bearingX
	render2d.SetColor(0.7, 0.4, 0, 1)
	drawArrow(ox, oy + (yMin + yMax) / 2, ox + xMin, oy + (yMin + yMax) / 2)
	labelFont:DrawText("bearingX", ox + xMin / 2 - 30, oy + (yMin + yMax) / 2 + 10)
	-- bearingY
	render2d.SetColor(0.5, 0, 0.5, 1)
	drawArrow(ox + (xMin + xMax) / 2, oy, ox + (xMin + xMax) / 2, oy + yMax)
	labelFont:DrawText("bearingY", ox + (xMin + xMax) / 2 + 5, oy + yMax / 2)
	-- advance
	render2d.SetColor(0, 0.5, 0.5, 1)
	drawArrow(ox, oy - 80, ox + advance, oy - 80)
	labelFont:DrawText("advance", ox + advance / 2 - 20, oy - 105)
	gfx.DrawLine(ox + advance, oy - 10, ox + advance, oy + 10, 2)
	gfx.DrawFilledCircle(ox + advance, oy, 4)
	-- xMin, xMax, yMin, yMax (markers)
	render2d.SetColor(0.4, 0.4, 0.4, 1)
	gfx.DrawLine(ox + xMin, oy + yMax, ox + xMin, oy + yMax + 60, 1)
	labelFont:DrawText("xMin", ox + xMin - 15, oy + yMax + 65)
	gfx.DrawLine(ox + xMax, oy + yMax, ox + xMax, oy + yMax + 60, 1)
	labelFont:DrawText("xMax", ox + xMax - 15, oy + yMax + 65)
	gfx.DrawLine(ox + xMax, oy + yMax, ox + xMax + 60, oy + yMax, 1)
	labelFont:DrawText("yMax", ox + xMax + 65, oy + yMax - 5)
	gfx.DrawLine(ox + xMax, oy + yMin, ox + xMax + 60, oy + yMin, 1)
	labelFont:DrawText("yMin", ox + xMax + 65, oy + yMin - 5)
end)
