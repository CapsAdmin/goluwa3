local T = require("test.environment")
local fonts = require("render2d.fonts")
local render = require("render.render")
local render2d = require("render2d.render2d")
local Vec2 = require("structs.vec2")

T.Test("Font rasterization and texture atlas", function()
	render.Initialize({headless = true})
	render2d.Initialize()
	local font_path = "/home/caps/Downloads/Exo_2/static/Exo2-Regular.ttf"
	-- Check if file exists first, if not we might need to skip or error gracefully
	-- Since the user said we CAN use it, I'll assume it exists if they are running it.
	local font = fonts.CreateFont({path = font_path, size = 20, padding = 2})
	T(font)["~="](nil)
	T(font.IsFont)["=="](true)
	T(font.Size)["=="](20)
	T(font:GetPadding())["=="](2)
	-- Test loading a specific glyph
	local char = "A"
	local char_code = string.byte(char)
	-- Initially the character shouldn't be loaded (atlas is built on CreateFont for already existing chars, but not new ones)
	-- Actually fonts.CreateFont calls fonts.LoadFont which calls rasterized_font.New.
	-- rasterized_font.New calls create_atlas which loads characters if self.chars is already populated.
	-- In this case self.chars is empty.
	-- Draw text or get size to trigger loading
	local w, h = font:GetTextSize("Hello")
	T(w)[">"](0)
	T(h)[">"](0)
	-- Check that glyphs are cached
	T(font.chars[string.byte("H")])["~="](nil)
	T(font.chars[string.byte("e")])["~="](nil)
	T(font.chars[string.byte("l")])["~="](nil)
	T(font.chars[string.byte("o")])["~="](nil)
	-- Check texture atlas
	local atlas = font.texture_atlas
	T(atlas)["~="](nil)
	T(#atlas:GetTextures())[">="](1)
	-- Check that GetPageTexture returns the same texture for common characters
	local tex_h = atlas:GetPageTexture(string.byte("H"))
	local tex_e = atlas:GetPageTexture(string.byte("e"))
	T(tex_h)["~="](nil)
	T(tex_h)["=="](tex_e) -- Should be on same page for short string
	-- Test batch loading
	font:GetTextSize("World")
	T(font.chars[string.byte("W")])["~="](nil)
	-- Test UTF-8
	local utf8_str = "🚀"
	font:GetTextSize(utf8_str)
	-- Rocket emoji is a multibyte utf8 char
	local utf8 = require("utf8")
	local code = utf8.uint32(utf8_str)
	T(font.chars[code])["~="](nil)
	-- Test texture atlas UVs
	local uv, aw, ah = atlas:GetNormalizedUV(string.byte("H"))
	T(#uv)["=="](4)
	T(aw)[">"](0)
	T(ah)[">"](0)
	-- Test manual rebuild
	font:RebuildFromScratch()
	T(font.chars[string.byte("H")])["~="](nil)
	-- Test shading info
	-- This should trigger pipeline creation and multi-pass rasterization
	font:SetShadingInfo(
		{
			{
				source = "return vec4(1.0, 0.0, 0.0, texture(self, uv).a);", -- Make it red
				blend_mode = "alpha",
			},
		}
	)
	-- Rebuild from scratch to apply shading
	font:RebuildFromScratch()
	T(font.chars[string.byte("H")])["~="](nil)
	-- Test multiple characters and atlas growth
	local long_str = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
	font:GetTextSize(long_str)

	for i = 1, #long_str do
		local char = long_str:sub(i, i)
		local code = string.byte(char)
		T(font.chars[code])["~="](nil)
		local data = atlas.textures[code]

		if not data then
			error("Atlas data missing for " .. char .. " (" .. code .. ")")
		end

		if not data.page then
			error("Atlas page missing for " .. char .. " (" .. code .. ")")
		end

		T(atlas:GetPageTexture(code))["~="](nil)
	end

	-- Test texture reuse for the same character
	local char_a = string.byte("a")
	local tex1 = atlas:GetPageTexture(char_a)
	local uv1 = atlas:GetNormalizedUV(char_a)
	font:LoadGlyph("a") -- Should be a no-op since it's already loaded
	local tex2 = atlas:GetPageTexture(char_a)
	local uv2 = atlas:GetNormalizedUV(char_a)
	T(tex1)["=="](tex2)
	T(uv1[1])["=="](uv2[1])
	T(uv1[2])["=="](uv2[2])
	-- Test multiline GetTextSize
	local w1, h1 = font:GetTextSize("Line 1")
	local w2, h2 = font:GetTextSize("Line 1\nLine 2")
	print("Height 1 line:", h1, "Height 2 lines:", h2)
	print("Line height:", font:GetLineHeight() * font.Scale.y)
	T(h2)[">"](h1 * 1.5)
-- With new logic, h2 should be roughly 2*h1 + spacing
-- Actually h2 should be exactly (line_height*2 + spacing) * scale.y
-- And h1 is line_height * scale.y
end)

T.Test("Atlas overflow and multiple pages", function()
	local fonts = require("render2d.fonts")
	local font_path = "/home/caps/Downloads/Exo_2/static/Exo2-Regular.ttf"
	local utf8 = require("utf8")
	local font = fonts.CreateFont({
		path = font_path,
		size = 64, -- 1024x1024 atlas
	})
	font:SetLoadSpeed(1000)

	-- Load many characters to force multiple pages
	-- Atlas is 1024x1024 for size 64.
	-- Each glyph is ~64x64. 1024/64 = 16 => 256 glyphs per page.
	-- We'll load 1000 glyphs across multiple batches.
	for chunk = 0, 9 do
		local s = ""

		for i = 32 + (chunk * 100), 32 + ((chunk + 1) * 100) do
			s = s .. utf8.from_uint32(i)
		end

		font:GetTextSize(s)
	end

	local pages = font.texture_atlas:GetTextures()
	print("Number of atlas pages for 1000 glyphs (size 64):", #pages)
	T(#pages)[">"](1)
	-- Check that we can still get UVs for high characters
	local code = 65
	local uv, aw, ah = font.texture_atlas:GetNormalizedUV(code)
	T(uv)["~="](nil)
	T(aw)[">"](0)
end)
