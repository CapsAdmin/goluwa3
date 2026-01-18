local ffi = require("ffi")
local Vec2 = require("structs.vec2")
local render2d = require("render2d.render2d")
local Texture = require("render.texture")
local Framebuffer = require("render.framebuffer")
local Buffer = require("structs.buffer")
local system = require("system")
local render = require("render.render")
local prototype = require("prototype")
local utf8 = require("utf8")
local TextureAtlas = require("render.texture_atlas")
local META = prototype.CreateTemplate("rasterized_font")
META:GetSet("Fonts", {})
META:GetSet("Padding", 0)
META:GetSet("Curve", 0)
META:IsSet("Spacing", 0)
META:IsSet("Size", 12)
META:IsSet("Scale", Vec2(1, 1))
META:GetSet("Filtering", "linear")
META:GetSet("ShadingInfo")
META:IsSet("Monospace", false)
META:IsSet("Ready", false)
META:IsSet("ReverseDraw", false)
META:GetSet("LoadSpeed", 10)
META:GetSet("TabWidthMultiplier", 4)
META:GetSet("Flags")

function META.New(fonts)
	if fonts.Type == "font" then fonts = {fonts} end

	local self = META:CreateObject()
	self:SetFonts(fonts)
	self.chars = {}
	self.rebuild = false

	-- Get size from first font
	if fonts[1] and fonts[1].Size then self:SetSize(fonts[1].Size) end

	self:CreateTextureAtlas()
	self:SetReady(true)
	return self
end

function META:CreateTextureAtlas()
	self.texture_atlas = TextureAtlas.New(512, 512, self.Filtering, render.target:GetColorFormat())
	self.texture_atlas:SetPadding(self.Padding)

	for code in pairs(self.chars) do
		self.chars[code] = nil
		self:LoadGlyph(code)
	end

	self.texture_atlas:Build()
end

function META:Shade(source, vars, blend_mode)
	error("Not implemented yet")

	if source then
		for _, tex in ipairs(self.texture_atlas:GetTextures()) do
			if tex.font_shade_keep then
				vars.copy = tex.font_shade_keep
			--tex.font_shade_keep = nil
			end

			tex:Shade(source, vars, blend_mode)
		end
	elseif self.ShadingInfo then
		self:CreateTextureAtlas()

		for _, info in ipairs(self.ShadingInfo) do
			if info.copy then
				for _, tex in ipairs(self.texture_atlas:GetTextures()) do
					tex.font_shade_keep = render.CreateBlankTexture(tex:GetSize())
					tex.font_shade_keep:Shade("return texture(tex, uv);", {tex = tex}, "none")
				end
			else
				self:Shade(info.source, info.vars, info.blend_mode)
			end
		end
	end
end

function META:Rebuild()
	if self.ShadingInfo then self:Shade() else self.texture_atlas:Build() end
end

function META:LoadGlyph(code)
	if self.chars[code] ~= nil then return end

	-- Convert string to character code if needed
	if type(code) == "string" then code = utf8.uint32(code) end

	local glyph
	local glyph_source_font

	for i = 1, #self.Fonts do
		local font = self.Fonts[i]
		glyph = font:GetGlyph(code)

		if glyph then
			glyph_source_font = font

			break
		end
	end

	if glyph then
		if not glyph.buffer and glyph.glyph_data and glyph.w > 0 and glyph.h > 0 then
			local fb = Framebuffer.New(
				{
					width = glyph.w,
					height = glyph.h,
					clear_color = {0, 0, 0, 0},
					format = render.target:GetColorFormat(),
				}
			)
			local cmd = fb:Begin()
			local old_cmd = render2d.cmd
			render2d.cmd = cmd
			local old_w, old_h = render2d.GetSize()
			render2d.UpdateScreenSize({w = glyph.w, h = glyph.h})
			render2d.pipeline:Bind(render2d.cmd, render.GetCurrentFrame())
			render2d.SetBlendMode(render2d.GetBlendMode(), true)
			render2d.PushMatrix()
			render2d.LoadIdentity()
			-- Reset color and UV for glyph capture
			render2d.SetColor(1, 1, 1, 1)
			render2d.SetUV()
			-- Flip coordinates so font (Y-down) renders right-side up in Y-up framebuffer
			render2d.Translate(0, glyph.h)
			render2d.Scale(1, -1)
			-- Shift glyph to be at (1, 1) in the framebuffer to avoid clipping and have a 1px margin
			render2d.Translatef(-glyph.bitmap_left + 1, -glyph.bitmap_top + 1)
			glyph_source_font:DrawGlyph(glyph.glyph_data)
			render2d.PopMatrix()
			fb:End()
			render2d.UpdateScreenSize({w = old_w, h = old_h})
			render2d.cmd = old_cmd
			--glyph.buffer = fb.color_texture:Download()
			glyph.texture = fb.color_texture
		--fb:Remove()
		end

		self.texture_atlas:Insert(
			code,
			{
				w = glyph.w,
				h = glyph.h,
				buffer = glyph.buffer,
				texture = glyph.texture,
				flip_y = glyph.flip_y,
			}
		)
		self.chars[code] = glyph
	else
		self.chars[code] = false
	end
end

function META:GetChar(char)
	local data = self.chars[char]

	if data == nil then
		self:LoadGlyph(char)
		self.rebuild = true
		return self.chars[char]
	end

	if char == "\n" then
		if data then
			if data.h <= 1 then data.h = self.Size end
		else
			data = {h = self.Size}
		end
	end

	return data
end

function META:GetTextSize(str)
	if not self.Ready then return 0, 0 end

	str = tostring(str)
	local X, Y = 0, self.Size
	local max_x = 0
	local spacing = self.Spacing

	for i, char in ipairs(utf8.to_list(str)) do
		local char_code = utf8.uint32(char)
		local data = self:GetChar(char_code)

		if char == "\n" then
			Y = Y + self:GetChar(utf8.uint32("\n")).h + spacing
			max_x = math.max(max_x, X)
			X = 0
		elseif char == "\t" then
			data = self:GetChar(utf8.uint32(" "))

			if data then
				if self.Monospace then
					X = X + spacing * self.TabWidthMultiplier
				else
					X = X + (data.x_advance + spacing) * self.TabWidthMultiplier
				end
			else
				X = X + self.Size * self.TabWidthMultiplier
			end
		elseif data then
			if self.Monospace then
				X = X + spacing
			else
				X = X + data.x_advance + spacing
			end
		elseif char == " " then
			X = X + self.Size / 2
		end
	end

	if max_x ~= 0 then X = max_x end

	return X * self.Scale.x, Y * self.Scale.y
end

function META:DrawString(str, x, y, spacing)
	if not self.Ready then return end

	str = tostring(str)
	spacing = spacing or self.Spacing

	if self.rebuild then
		self:Rebuild()
		self.rebuild = false
	end

	local X, Y = 0, 0

	for i, char in ipairs(utf8.to_list(str)) do
		local char_code = utf8.uint32(char)
		local data = self:GetChar(char_code)

		if char == "\n" then
			X = 0
			Y = Y + self:GetChar(utf8.uint32("\n")).h + spacing
		elseif char == "\t" then
			data = self:GetChar(utf8.uint32(" "))

			if data then
				if self.Monospace then
					X = X + spacing * self.TabWidthMultiplier
				else
					X = X + (data.x_advance + spacing) * self.TabWidthMultiplier
				end
			else
				X = X + self.Size * self.TabWidthMultiplier
			end
		elseif data then
			-- Rebuild atlas if new glyphs were loaded
			if self.rebuild then
				self:Rebuild()
				self.rebuild = false
			end

			local texture = self.texture_atlas:GetPageTexture(char_code)

			if texture then
				render2d.SetTexture(texture)
				local u1, v1, w, h, sx, sy = self.texture_atlas:GetUV(char_code)
				render2d.PushMatrix()
				render2d.Translate(
					x + (X + data.bitmap_left) * self.Scale.x,
					y - (Y + (data.h - data.bitmap_top - data.h)) * self.Scale.y
				)
				render2d.PushUV()
				render2d.SetUV2(u1 / sx, v1 / sy, (u1 + w) / sx, (v1 + h) / sy)
				render2d.DrawRect(0, 0, w * self.Scale.x, h * self.Scale.y)
				render2d.PopUV()
				render2d.PopMatrix()
			end

			if self.Monospace then
				X = X + spacing
			else
				X = X + data.x_advance + spacing
			end
		elseif char == " " then
			X = X + self.Size / 2
		end
	end
end

return META:Register()
