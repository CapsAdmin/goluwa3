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
	local width = math.ceil(glyph.w + padding * 2)
	local height = math.ceil(glyph.h + padding * 2)
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
		render2d.SetSwizzleMode("none")
		render2d.PushMatrix()
		render2d.LoadIdentity()
		render2d.Translate(padding, padding)
		render2d.Translate(-glyph.bitmap_left, -glyph.bitmap_top)
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
	glyph.atlas_data = {
		w = width,
		h = height,
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
	self:StartCollectTempResources()
	render.PushCommandBuffer(cmd)

	while i <= len do
		local cc = utf8.uint32(str, i)
		self:LoadGlyph(cc)
		i = i + utf8.byte_length(str, i)
	end

	self:Rebuild()
	render.PopCommandBuffer()
	cmd:End()
	render.SubmitAndWait(cmd)
	self.rebuild = false
	self:ReleaseTempResources()
end

local function glyph_fn(self, data, X, Y, _)
	local atlas_data = self.texture_atlas.textures[data.char_code]

	if atlas_data and atlas_data.page then
		local padding = self:GetPadding()
		local texture = atlas_data.page.texture

		if texture ~= self.last_texture then
			render2d.SetTexture(texture)
			self.last_texture = texture
		end

		local uv = atlas_data.page_uv
		local rx = (X + data.bitmap_left - padding) * self.Scale.x
		local ry = (Y + data.bitmap_top - padding) * self.Scale.y
		local rw = atlas_data.w * self.Scale.x
		local rh = atlas_data.h * self.Scale.y
		render2d.PushColorUV(uv[1], uv[4], uv[3], uv[2])
		render2d.DrawRect(rx, ry, rw, rh)
		render2d.PopColorUV()
	end
end

function META:DrawString(str, x, y, spacing, extra_space_advance)
	str = tostring(str)
	batch_load_glyphs(self, str)
	spacing = spacing or self.Spacing
	extra_space_advance = extra_space_advance or 0
	render2d.PushSDFUV()
	self.last_texture = nil
	render2d.Translate(x, y)
	self:BuildLayout(str, spacing, extra_space_advance, glyph_fn)
	render2d.Translate(-x, -y)
	render2d.PopSDFUV()
end

return META:Register()
