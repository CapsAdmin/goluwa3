local event = import("goluwa/event.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local fonts = import("goluwa/render2d/fonts.lua")
local RasterFont = import("goluwa/render2d/fonts/raster.lua")
local glyphs = import("goluwa/render2d/glyphs.lua")
local font_path = fonts.GetDefaultSystemFontPath()
-- Create fonts of each type
local sdf_font = fonts.New{Path = font_path, Size = 48}
local raster_font = RasterFont.New("bitmap")
local label_font = fonts.New{Path = font_path, Size = 14}
local test_text = "The quick, brown fox. jumps over the lazy dog!?"

event.AddListener("Draw2D", "fonts_showcase", function()
	render2d.SetTexture(nil)
	render2d.SetColor(0.12, 0.12, 0.14, 1)
	render2d.DrawRect(0, 0, render2d.GetSize())
	local x, y = 40, 40
	-- SDF Font
	render2d.SetColor(1, 1, 1, 1)
	label_font:DrawText("SDF Font", x, y)
	sdf_font:DrawText(test_text, x, y + 25)
	y = y + 80
	-- Bitmap Font
	label_font:DrawText("Bitmap Font", x, y)
	raster_font:DrawText(test_text, x, y + 25)
	y = y + 60
	-- Glyph Metrics
	y = y + 20
	label_font:DrawText("Glyph Metrics ('g')", x, y)
	y = y + 25
	local g_glyph = sdf_font:LoadGlyph(103) -- 'g'
	if g_glyph then
		local ascent = sdf_font:GetAscent()
		local descent = sdf_font:GetDescent()
		local line_height = sdf_font:GetLineHeight()
		label_font:DrawText("ascent: " .. string.format("%.1f", ascent), x, y)
		y = y + 20
		label_font:DrawText("descent: " .. string.format("%.1f", descent), x, y)
		y = y + 20
		label_font:DrawText("line height: " .. string.format("%.1f", line_height), x, y)
		y = y + 20
		label_font:DrawText("glyph advance: " .. string.format("%.1f", g_glyph.x_advance), x, y)
		y = y + 20
		label_font:DrawText(
			"glyph size: " .. string.format("%.0f", g_glyph.w) .. "x" .. string.format("%.0f", g_glyph.h),
			x,
			y
		)
		y = y + 20
		label_font:DrawText("bitmap: " .. g_glyph.bitmap_left .. ", " .. g_glyph.bitmap_top, x, y)
		y = y + 20
		-- Draw the glyph with metrics visualization
		render2d.PushColor(0.3, 0.3, 0.3, 1)
		render2d.DrawLine(x, y, x + 300, y, 1) -- baseline
		render2d.PopColor()
		sdf_font:DrawText("g", x, y)
		render2d.PushColor(1, 0.3, 0.3, 0.5)
		render2d.DrawRect(x + g_glyph.bitmap_left, y - g_glyph.bitmap_top, g_glyph.w, g_glyph.h)
		render2d.PopColor()
	end

	-- Raw glyph data from glyphs module
	y = y + 60
	label_font:DrawText("Raw Glyph Data (from glyphs module)", x, y)
	y = y + 25
	local raw = glyphs.GetGlyph(font_path, 88) -- 'X'
	if raw then
		label_font:DrawText("advance: " .. string.format("%.4f", raw.x_advance), x, y)
		y = y + 20
		label_font:DrawText(
			"bounds: " .. string.format("%.4f", raw.w) .. "x" .. string.format("%.4f", raw.h),
			x,
			y
		)
		y = y + 20
		label_font:DrawText("has polygon: " .. tostring(raw.poly ~= nil), x, y)
	end
end)
