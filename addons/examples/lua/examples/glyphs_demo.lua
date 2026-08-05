local event = import("goluwa/event.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local glyphs = import("goluwa/render2d/glyphs.lua")
local fonts = import("goluwa/render2d/fonts.lua")
local utf8 = import("goluwa/string/utf8.lua")
local font_path = fonts.GetDefaultSystemFontPath()
local font = fonts.New{Path = font_path, Size = 20}

event.AddListener("Draw2D", "glyphs_demo", function()
	render2d.SetTexture(nil)
	local x, y = 50, 50
	local text = "Hello glyphs!"
	local sizes = {16, 32, 48, 64}

	for _, size in ipairs(sizes) do
		local cx = x
		render2d.PushColor(1, 1, 1, 1)

		for _, char in ipairs(utf8.to_list(text)) do
			local cp = utf8.uint32(char)
			local glyph = glyphs.GetGlyph(font_path, cp)

			if glyph then
				glyphs.DrawGlyph(font_path, cp, cx, y, size)
				cx = cx + glyph.x_advance * size
			end
		end

		render2d.PopColor()
		y = y + size + 10
	end

	-- glyph metrics
	y = y + 20
	local test_glyph = glyphs.GetGlyph(font_path, "X")

	if test_glyph then
		render2d.PushColor(0.5, 1, 0.5, 1)
		font:DrawText("Glyph 'X': raw_advance=" .. string.format("%.1f", test_glyph.x_advance), x, y)
		render2d.PopColor()
	end
end)
