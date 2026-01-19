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
	local atlas_size = 512

	if self.Size > 32 then atlas_size = 1024 end

	if self.Size > 64 then atlas_size = 2048 end

	if self.Size > 128 then atlas_size = 4096 end

	self.texture_atlas = TextureAtlas.New(atlas_size, atlas_size, self.Filtering, render.target:GetColorFormat())
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

function META:GetAscent()
	return self.Fonts[1]:GetAscent()
end

function META:GetDescent()
	return self.Fonts[1]:GetDescent()
end

function META:Rebuild()
	if self.ShadingInfo then self:Shade() else self.texture_atlas:Build() end
end

function META:LoadGlyph(code)
	-- Convert string to character code if needed
	if type(code) == "string" then code = utf8.uint32(code) end

	if self.chars[code] ~= nil then return end

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
			local scale = 4
			local fb_ss = Framebuffer.New(
				{
					width = glyph.w * scale,
					height = glyph.h * scale,
					clear_color = {1, 1, 1, 0},
					format = render.target:GetColorFormat(),
				}
			)
			local old_cmd = render2d.cmd
			local old_w, old_h = render2d.GetSize()
			render2d.PushColor(render2d.GetColor())
			render2d.PushUV()
			render2d.PushBlendMode(render2d.GetBlendMode())
			render2d.PushTexture(render2d.GetTexture())
			render2d.PushAlphaMultiplier(render2d.GetAlphaMultiplier())
			render2d.PushSwizzleMode(render2d.GetSwizzleMode())

			do
				local cmd = fb_ss:Begin()
				render2d.cmd = cmd
				render2d.PushSamples("1")
				render2d.UpdateScreenSize({w = glyph.w * scale, h = glyph.h * scale})
				render2d.pipeline:Bind(render2d.cmd, render.GetCurrentFrame())
				render2d.SetColor(1, 1, 1, 1)
				render2d.SetUV()
				render2d.SetBlendMode("alpha", true)
				render2d.SetAlphaMultiplier(1)
				render2d.SetSwizzleMode(0)
				render2d.PushMatrix()
				render2d.LoadIdentity()
				-- Flip coordinates so font (Y-down) renders right-side up in Y-up framebuffer
				render2d.Translate(0, glyph.h * scale)
				render2d.Scale(scale, -scale)
				-- Shift glyph to be at (1, 1) in the framebuffer to avoid clipping and have a 1px margin
				render2d.Translatef(-glyph.bitmap_left + 1, -glyph.bitmap_top + 1)
				glyph_source_font:DrawGlyph(glyph.glyph_data)
				render2d.PopMatrix()
				render2d.PopSamples()
				fb_ss:End()
			end

			local fb = Framebuffer.New(
				{
					width = glyph.w,
					height = glyph.h,
					clear_color = {1, 1, 1, 0},
					format = render.target:GetColorFormat(),
				}
			)

			do
				local cmd = fb:Begin()
				render2d.cmd = cmd
				render2d.PushSamples("1")
				render2d.UpdateScreenSize({w = glyph.w, h = glyph.h})
				render2d.pipeline:Bind(render2d.cmd, render.GetCurrentFrame())
				render2d.SetColor(1, 1, 1, 1)
				render2d.SetBlendMode("none", true)
				render2d.SetUV2(0, 1, 1, 0)
				render2d.SetTexture(fb_ss.color_texture)
				render2d.SetAlphaMultiplier(1)
				render2d.SetSwizzleMode(0)
				render2d.PushMatrix()
				render2d.LoadIdentity()
				render2d.DrawRect(0, 0, glyph.w, glyph.h)
				render2d.PopMatrix()
				render2d.PopSamples()
				fb:End()
			end

			render2d.cmd = old_cmd
			render2d.UpdateScreenSize({w = old_w, h = old_h})
			render2d.PopSwizzleMode()
			render2d.PopAlphaMultiplier()
			render2d.PopTexture()
			render2d.PopBlendMode()
			render2d.PopUV()
			render2d.PopColor()
			--glyph.buffer = fb.color_texture:Download()
			glyph.texture = fb.color_texture
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

function META:GetTextSizeNotCached(str)
	if not self.Ready then return 0, 0 end

	str = tostring(str)
	local X, Y = 0, self:GetAscent()
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
					y + (Y + data.bitmap_top) * self.Scale.y
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

do
	-- Drawing functions
	function META:DrawText(str, x, y, spacing, align_x, align_y)
		if align_x or align_y then
			local w, h = self:GetTextSize(str)

			if type(align_x) == "number" then
				x = x - (w * align_x)
			elseif align_x == "center" then
				x = x - (w / 2)
			elseif align_x == "right" then
				x = x - w
			end

			if type(align_y) == "number" then
				y = y - (h * align_y)
			elseif align_y == "baseline" then
				y = y - self:GetAscent()
			elseif align_y == "center" then
				y = y - (h / 2)
			elseif align_y == "bottom" then
				y = y - h
			end
		end

		self:DrawString(str, x, y, spacing)
	end

	do
		local cache = {} or table.weak()

		function META:GetTextSize(str)
			str = str or "|"

			if cache[self] and cache[self][str] then
				return cache[self][str][1], cache[self][str][2]
			end

			local x, y = self:GetTextSizeNotCached(str)
			cache[self] = cache[self] or table.weak()
			cache[self][str] = cache[self][str] or table.weak()
			cache[self][str][1] = x
			cache[self][str][2] = y
			return x, y
		end
	end

	do -- text wrap
		local function wrap_1(str, max_width)
			local lines = {}
			local i = 1
			local last_pos = 0
			local line_width = 0
			local space_pos
			local tbl = str:utf8_to_list()

			--local pos = 1
			--for _ = 1, 10000 do
			--	local char = tbl[pos]
			--	if not char then break end
			for pos, char in ipairs(tbl) do
				local w = fonts.GetTextSize(font, char)

				if char:find("%s") then space_pos = pos end

				if line_width + w >= max_width then
					if space_pos then
						lines[i] = str:utf8_sub(last_pos + 1, space_pos)
						last_pos = space_pos
					else
						lines[i] = str:utf8_sub(last_pos + 1, pos)
						last_pos = pos
					end

					i = i + 1
					line_width = 0
					space_pos = nil
				end

				line_width = line_width + w
			--pos = pos + 1
			end

			if lines[1] then
				lines[i] = str:utf8_sub(last_pos + 1)
				return list.concat(lines, "\n")
			end

			return str
		end

		local function wrap_2(self, str, max_width)
			local tbl = str:utf8_to_list()
			local lines = {}
			local chars = {}
			local i = 1
			local width = 0
			local width_before_last_space = 0
			local width_of_trailing_space = 0
			local last_space_index = -1
			local prev_char

			while i < #tbl do
				local c = tbl[i]
				local char_width = self:GetTextSize(c)
				local new_width = width + char_width

				if c == "\n" then
					list.insert(lines, list.concat(chars))
					list.clear(chars)
					width = 0
					width_before_last_space = 0
					width_of_trailing_space = 0
					prev_char = nil
					last_space_index = -1
					i = i + 1
				elseif char ~= " " and width >= max_width then
					if #chars == 0 then
						i = i + 1
					elseif last_space_index ~= -1 then
						for i = #chars, 1, -1 do
							if chars[i] == " " then break end

							list.remove(chars, i)
						end

						width = width_before_last_space
						i = last_space_index
						i = i + 1
					end

					list.insert(lines, list.concat(chars))
					list.clear(chars)
					prev_char = nil
					width = char_width
					width_before_last_space = 0
					width_of_trailing_space = 0
					last_space_index = -1
				else
					if prev_char ~= " " and c == " " then
						width_before_last_space = width
					end

					width = new_width
					prev_char = c
					list.insert(chars, c)

					if c == " " then
						last_space_index = i
					elseif c ~= "\n" then
						width_of_trailing_space = 0
					end

					i = i + 1
				end
			end

			if #chars ~= 0 then list.insert(lines, list.concat(chars)) end

			return list.concat(lines, "\n")
		end

		local cache = table.weak()

		function META:WrapString(str, max_width)
			if cache[str] and cache[str][max_width] and cache[str][max_width][self] then
				return cache[str][max_width][self]
			end

			if max_width < self:GetTextSize(self, nil) then
				return list.concat(str:split(""), "\n")
			end

			if max_width > self:GetTextSize(str) then return str end

			local res = wrap_2(self, str, max_width)
			cache[str] = cache[str] or {}
			cache[str][max_width] = cache[str][max_width] or {}
			cache[str][max_width][self] = res
			return res
		end
	end
end

return META:Register()
