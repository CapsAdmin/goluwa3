--[[HOTRELOAD
	os.execute("luajit glw test raster")
]]
local render2d = import("goluwa/render2d/render2d.lua")
local render = import("goluwa/render/render.lua")
local objects = import("goluwa/objects/objects.lua")
local utf8 = import("goluwa/string/utf8.lua")
local TextureAtlas = import("goluwa/render/texture_atlas.lua")
local event = import("goluwa/event.lua")
local AtlasFont = import("goluwa/render2d/fonts/atlas_font.lua")
local META = objects.CreateTemplate("raster_font")
META.Base = AtlasFont
META.debug = false

function META:__copy()
	return self
end

function META.New(fonts)
	if type(fonts) == "table" and fonts.IsFont then fonts = {fonts} end

	local self = META:CreateObject()
	self.tr = debug.traceback()
	self:SetFonts(fonts)
	self.chars = {}
	self.rebuild = false

	if render.target:IsValid() then
		self:CreateAtlas()
	else
		event.AddListener("RendererReady", self, function()
			self:CreateAtlas()
			return event.destroy_tag
		end)
	end

	return self
end

function META:GetAtlasFormat()
	return render.target:GetColorFormat()
end

function META:CreateAtlas()
	local format = self:GetAtlasFormat()
	self.texture_atlas = TextureAtlas.New(1024, 1024, self.Filtering, format)
	self.texture_atlas:SetDebugName(
		string.format(
			"render2d raster font atlas %s size=%s",
			tostring(self:GetName() or "unnamed"),
			tostring(self:GetSize())
		)
	)
	self.texture_atlas:SetPadding(self:GetPadding())

	for code in pairs(self.chars) do
		self.chars[code] = nil
		self:LoadGlyph(code)
	end

	self.texture_atlas:Build()
	self:SetReady(true)
end

local scratch_size = {w = 0, h = 0}

local function render_glyph_to_texture(self, glyph_source_font, glyph, temp_fbs)
	local padding = self:GetPadding()
	local effective_h = math.max(glyph.h, glyph.bitmap_top)
	local width = math.max(1, math.ceil(glyph.w + padding * 2))
	local height = math.max(1, math.ceil(effective_h + padding * 2))
	local format = self:GetAtlasFormat()
	local fb = self:GetTempFramebuffer(width, height, format, true, self.Filtering)
	table.insert(temp_fbs, fb)
	local cmd = render.GetCommandPool():AllocateCommandBuffer()
	cmd:Begin()

	do
		render2d.ResetState()
		local old_w, old_h = render2d.GetSize()
		render.PushCommandBuffer(cmd)
		fb:Begin(cmd)
		local old_color = {render2d.GetColor()}
		local old_blend_mode = render2d.GetBlendMode()
		render2d.SetColor(1, 1, 1, 1)
		render2d.SetBlendPreset("alpha")
		render2d.PushSwizzleMode(render2d.GetSwizzleMode())
		scratch_size.w = width
		scratch_size.h = height
		render2d.SetScreenSize(scratch_size.w, scratch_size.h)
		render2d.BindPipeline()
		render2d.SetSwizzleMode(0)
		render2d.PushMatrix()
		render2d.LoadIdentity()
		render2d.Translate(padding, effective_h + padding)
		render2d.Scale(1, -1)
		render2d.Translatef(-glyph.bitmap_left, -glyph.bitmap_top)
		glyph_source_font:DrawGlyph(glyph.glyph_data)
		render2d.PopMatrix()
		render2d.PopSwizzleMode()
		render2d.SetBlendMode(old_blend_mode, true)
		render2d.SetColor(unpack(old_color))
		fb:End()
		render.PopCommandBuffer()
		scratch_size.w = old_w
		scratch_size.h = old_h
		render2d.SetScreenSize(scratch_size.w, scratch_size.h)
	end

	cmd:End()
	render.SubmitAndWait(cmd)
	return fb.color_texture, width, height
end

function META:LoadGlyph(code, temp_fbs)
	if type(code) == "string" then code = utf8.uint32(code) end

	if self.chars[code] ~= nil then return end

	local glyph
	local glyph_source_font

	for i = 1, #self.Fonts do
		local font = self.Fonts[i]
		font:SetSize(self.Size)
		glyph = font:GetGlyph(code)

		if glyph then
			glyph_source_font = font

			break
		end
	end

	if not glyph then
		self.chars[code] = false
		return
	end

	if glyph.glyph_data and glyph.w > 0 and glyph.h > 0 then
		if not render.available or not render.target then return end

		local used_temp_fbs = {}
		glyph.texture, glyph.raster_w, glyph.raster_h = render_glyph_to_texture(self, glyph_source_font, glyph, used_temp_fbs)
		local padding = self:GetPadding()
		local effective_h = math.max(glyph.h, glyph.bitmap_top)
		local atlas_w = math.max(1, math.ceil(glyph.w + padding * 2))
		local atlas_h = math.max(1, math.ceil(effective_h + padding * 2))

		if not temp_fbs then
			for _, fb in ipairs(used_temp_fbs) do
				self:ReleaseTempFramebuffer(fb)
			end
		else
			for _, fb in ipairs(used_temp_fbs) do
				table.insert(temp_fbs, fb)
			end
		end

		self.texture_atlas:Insert(
			code,
			{
				w = atlas_w,
				h = atlas_h,
				texture = glyph.texture,
				flip_y = glyph.flip_y,
			}
		)
	end

	self.chars[code] = glyph
end

local function batch_load_glyphs(self, str)
	local i = 1
	local len = #str
	local chars = self.chars

	if not self.rebuild then
		while i <= len do
			local char_code = utf8.uint32(str, i)

			if chars[char_code] == nil then break end

			i = i + utf8.byte_length(str, i)
		end

		if i > len then return end
	end

	local cmd = render.GetCommandPool():AllocateCommandBuffer()
	cmd:Begin()
	local temp_fbs = {}
	render.PushCommandBuffer(cmd)

	while i <= len do
		local cc = utf8.uint32(str, i)
		self:LoadGlyph(cc, temp_fbs)
		i = i + utf8.byte_length(str, i)
	end

	self:Rebuild()
	render.PopCommandBuffer()
	cmd:End()
	render.SubmitAndWait(cmd)
	self.rebuild = false

	for _, fb in ipairs(temp_fbs) do
		self:ReleaseTempFramebuffer(fb)
	end
end

function META:DrawPass(str, x, y, spacing, atlas, extra_space_advance)
	local X, Y = 0, 0
	local i = 1
	local len = #str
	local padding = self:GetPadding()
	extra_space_advance = extra_space_advance or 0
	local last_texture = nil

	while i <= len do
		local char_code = utf8.uint32(str, i)

		if char_code == 10 then
			X = 0
			Y = Y + self:GetLineHeight() + spacing
		elseif char_code == 32 then
			X = X + self.Size / 2 + extra_space_advance
		elseif char_code == 9 then
			local data = self.chars[32] or self:GetChar(32)

			if data then
				if self.Monospace then
					X = X + spacing * 4
				else
					X = X + (data.x_advance + spacing) * 4
				end
			else
				X = X + self.Size * 4
			end
		else
			local data = self.chars[char_code]

			if data then
				local atlas_data = atlas.textures[char_code]

				if atlas_data and atlas_data.page then
					local texture = atlas_data.page.texture

					if texture ~= last_texture then
						render2d.SetTexture(texture)
						last_texture = texture
					end

					local uv = atlas_data.page_uv_normalized
					local rx = x + (X + data.bitmap_left - padding) * self.Scale.x
					local ry = y + (Y + data.bitmap_top - padding) * self.Scale.y
					local rw = atlas_data.w * self.Scale.x
					local rh = atlas_data.h * self.Scale.y
					render2d.DrawRectUV2f(rx, ry, rw, rh, uv[1], uv[2], uv[3], uv[4])

					if self.debug then
						render2d.SetTexture(nil)
						render2d.PushColor(1, 0, 0, 0.25)
						render2d.DrawRect(
							x + (X - padding) * self.Scale.x,
							y + (Y - padding) * self.Scale.y,
							(data.x_advance + padding * 2) * self.Scale.x,
							self:GetLineHeight() * self.Scale.y
						)
						render2d.PopColor()
						render2d.SetTexture(texture)
					end
				end

				if self.Monospace then
					X = X + spacing
				else
					X = X + data.x_advance + spacing
				end
			end
		end

		i = i + utf8.byte_length(str, i)
	end
end

function META:DrawString(str, x, y, spacing, extra_space_advance)
	if not self:IsReady() then return end

	str = tostring(str)
	batch_load_glyphs(self, str)
	spacing = spacing or self.Spacing
	render2d.PushUV()
	self:DrawPass(str, x, y, spacing, self.texture_atlas, extra_space_advance)
	render2d.PopUV()
end

return META:Register()
