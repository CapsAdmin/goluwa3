do
	return
end

local event = require("event")
local render2d = require("render2d.render2d")
local gfx = require("render2d.gfx")
local fonts = require("render2d.fonts")
local font = fonts.LoadFont("/home/caps/Downloads/Roboto/static/Roboto-Regular.ttf", 50)
local str = ""

for i = 33, 127 do
	str = str .. string.char(i)
end

local once = false

event.AddListener("Draw2D", "ttftest", function()
	--render2d.PushMatrix()
	--render2d.Scale(6)
	font.texture_atlas:DebugDraw()

	if not once then
		for i, chunk in ipairs(str:length_split(20)) do
			--font.Fonts[1]:DrawString(chunk, 20, 20 + (i - 1) * 20)
			fonts.SetFont(font)
			fonts.DrawText(chunk, 20, 20 + (i - 1) * 60)
		end

		once = true
	end

	fonts.DrawText("hello world", 300, 300)
--font.Fonts[1]:DrawGlyph(g)
--render2d.PopMatrix()
end)
