--[[HOTRELOAD
	os.execute("luajit glw test raster")
]]
local render2d = import("goluwa/render2d/render2d.lua")
local render = import("goluwa/render/render.lua")
local objects = import("goluwa/objects/objects.lua")
local utf8 = import("goluwa/string/utf8.lua")
local TextureAtlas = import("goluwa/render/texture_atlas.lua")
local event = import("goluwa/event.lua")
local META = objects.CreateTemplate("raster_font")
META.Base = import("goluwa/render2d/fonts/base.lua")
META.debug = false

function META.New(font_path)
	local self = META:CreateObject()
	self:Initialize(font_path)
	return self
end

function META:GetAtlasFormat()
	return render.target:GetColorFormat()
end

function META:RenderGlyph(glyph, temp_fbs)
	local padding = self:GetPadding()
	local effective_h = self:GetAscent()
	local width = math.max(1, math.ceil(glyph.w + padding * 2))
	local height = math.max(1, math.ceil(glyph.h + glyph.bitmap_top + padding * 2))
	local format = self:GetAtlasFormat()
	local fb = self:GetTempFramebuffer(width, height, format, true, self.Filtering)
	table.insert(temp_fbs, fb)
	local cmd = render.GetCommandPool():AllocateCommandBuffer()
	cmd:Begin()

	do
		local old_w, old_h = render2d.GetSize()
		local saved_batch = render2d.SaveBatchState()
		render2d.state.runtime.batch.state:ClearPending()
		render.PushCommandBuffer(cmd)
		fb:Begin(cmd)
		render2d.ResetState()
		local old_color = {render2d.GetColor()}
		local old_blend_mode = render2d.GetBlendMode()
		render2d.SetColor(1, 1, 1, 1)
		render2d.SetBlendPreset("alpha")
		render2d.PushSwizzleMode(render2d.GetSwizzleMode())
		render2d.PushScreenSize(width, height)
		render2d.BindPipeline()
		render2d.SetSwizzleMode(0)
		render2d.PushMatrix()
		render2d.LoadIdentity()
		render2d.Translate(padding, effective_h + padding)
		render2d.Scale(1, -1)
		render2d.Translatef(-glyph.bitmap_left, -glyph.bitmap_top)
		self:DrawGlyph(glyph.glyph_data)
		render2d.FlushBatches("glyph_load")
		render2d.PopMatrix()
		render2d.PopSwizzleMode()
		render2d.SetBlendMode(old_blend_mode, true)
		render2d.SetColor(unpack(old_color))
		render2d.RestoreBatchState(saved_batch)
		fb:End(cmd)
		render.PopCommandBuffer()
		render2d.PopScreenSize()
	end

	cmd:End()
	render.SubmitAndWait(cmd)
	glyph.texture = fb.color_texture
	glyph.raster_w = width
	glyph.raster_h = height
	glyph.atlas_data = {
		w = math.max(1, math.ceil(glyph.w + self:GetPadding() * 2)),
		h = math.max(1, math.ceil(math.max(glyph.h, glyph.bitmap_top) + padding * 2)),
		texture = glyph.texture,
		flip_y = glyph.flip_y,
	}
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

function META:DrawString(str, x, y, spacing, extra_space_advance)
	str = tostring(str)
	batch_load_glyphs(self, str)
	spacing = spacing or self.Spacing
	render2d.PushUV()
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
			local data = self.chars[32] or self:LoadGlyph(32)

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
				local atlas_data = self.texture_atlas.textures[char_code]

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
			else
				-- Glyph not available, advance by default width
				X = X + self.Size + spacing
			end
		end

		i = i + utf8.byte_length(str, i)
	end

	render2d.PopUV()
end

return META:Register()
