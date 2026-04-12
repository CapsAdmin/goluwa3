--[[HOTRELOAD
	os.execute("luajit glw test raster")
]]
local Vec2 = import("goluwa/structs/vec2.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local Framebuffer = import("goluwa/render/framebuffer.lua")
local render = import("goluwa/render/render.lua")
local prototype = import("goluwa/prototype.lua")
local utf8 = import("goluwa/utf8.lua")
local event = import("goluwa/event.lua")
local TextureAtlas = import("goluwa/render/texture_atlas.lua")
local pretext = import("goluwa/pretext/init.lua")
local META = prototype.CreateTemplate("raster_font")
META.IsFont = true
META:GetSet("Fonts", {}, {callback = "OnFontsChanged"})
META:GetSet("Padding", 1, {callback = "OnPaddingChanged"})
META:GetSet("Spacing", 0, {callback = "ClearSizeCache"})
META:GetSet("Size", 12, {callback = "ClearSizeCache"})
META:GetSet("Scale", Vec2(1, 1), {callback = "ClearSizeCache"})
META:GetSet("Filtering", "linear", {callback = "ClearSizeCache"})
META:IsSet("Monospace", false, {callback = "ClearSizeCache"})
META:IsSet("Ready", false)
META.debug = false

function META:__copy()
	return self
end

function META:ClearSizeCache()
	self.text_size_cache = nil
	self.wrap_string_cache = nil
	self.ascent = nil
	self.descent = nil
end

function META:OnFontsChanged()
	self:ClearSizeCache()

	if self.Ready then self:RebuildFromScratch() end

	event.Call("OnFontsChanged", self)
end

function META:OnPaddingChanged()
	if self.texture_atlas then
		self.texture_atlas:SetPadding(self.Padding)
		self:ClearSizeCache()

		if self.Ready then self:RebuildFromScratch() end
	end
end

function META:OnRemove()
	if self.texture_atlas then self.texture_atlas:Remove() end
end

local function get_ascent_descent(self)
	if not self.ascent then
		self.Fonts[1]:SetSize(self.Size)
		self.ascent = self.Fonts[1]:GetAscent()
		self.descent = self.Fonts[1]:GetDescent()
	end

	return self.ascent, self.descent
end

function META:GetAtlasFormat()
	return render.target:GetColorFormat()
end

local function create_atlas(self)
	local format = self:GetAtlasFormat()
	self.texture_atlas = TextureAtlas.New(1024, 1024, self.Filtering, format)
	self.texture_atlas:SetPadding(self:GetPadding())

	for code in pairs(self.chars) do
		self.chars[code] = nil
		self:LoadGlyph(code)
	end

	self.texture_atlas:Build()
	self:SetReady(true)
end

function META.New(fonts)
	if type(fonts) == "table" and fonts.IsFont then fonts = {fonts} end

	local self = META:CreateObject()
	self.tr = debug.traceback()
	self:SetFonts(fonts)
	self.chars = {}
	self.rebuild = false

	if render.target:IsValid() then
		create_atlas(self)
	else
		event.AddListener("RendererReady", self, function()
			create_atlas(self)
			return event.destroy_tag
		end)
	end

	return self
end

function META:GetAscent()
	local a = get_ascent_descent(self)
	return a
end

function META:GetDescent()
	local _, d = get_ascent_descent(self)
	return d
end

function META:Rebuild()
	self.texture_atlas:Build()
end

function META:RebuildFromScratch()
	if not self.texture_atlas then return end

	local own_cmd = false
	local cmd = render.GetCommandBuffer()

	if not cmd then
		cmd = render.GetCommandPool():AllocateCommandBuffer()
		cmd:Begin()
		own_cmd = true
	end

	render.PushCommandBuffer(cmd)
	local codes_to_reload = {}

	for code in pairs(self.chars) do
		table.insert(codes_to_reload, code)
		self.chars[code] = nil
	end

	for _, code in ipairs(codes_to_reload) do
		self:LoadGlyph(code)
	end

	self:Rebuild()
	render.PopCommandBuffer()

	if own_cmd then
		cmd:End()
		render.SubmitAndWait(cmd)
	end
end

local scratch_size = {w = 0, h = 0}
local fb_pool = {}

local function get_temp_fb(w, h, format, mip_maps, filter)
	local key = w .. "_" .. h .. "_" .. format .. (
			mip_maps and
			"_t" or
			"_f"
		) .. (
			filter or
			"linear"
		)
	local pool = fb_pool[key]

	if not pool then
		pool = {}
		fb_pool[key] = pool
	end

	local fb = table.remove(pool)

	if not fb then
		fb = Framebuffer.New{
			width = w,
			height = h,
			clear_color = {0, 0, 0, 0},
			format = format,
			mip_map_levels = mip_maps and "auto" or 1,
			min_filter = filter or "linear",
			mag_filter = filter or "linear",
			wrap_s = "clamp_to_edge",
			wrap_t = "clamp_to_edge",
		}
		fb._pool_key = key
	end

	return fb
end

local function release_temp_fb(fb)
	local key = fb._pool_key
	local pool = fb_pool[key]

	if not pool then
		pool = {}
		fb_pool[key] = pool
	end

	table.insert(pool, fb)
end

local function render_glyph_to_texture(self, glyph_source_font, glyph, temp_fbs)
	local padding = self:GetPadding()
	local width = math.max(1, math.ceil(glyph.w + padding * 2))
	local height = math.max(1, math.ceil(glyph.h + padding * 2))
	local format = self:GetAtlasFormat()
	local fb = get_temp_fb(width, height, format, true, self.Filtering)
	table.insert(temp_fbs, fb)
	local own_cmd = false
	local cmd = render.GetCommandBuffer()

	if not cmd then
		cmd = render.GetCommandPool():AllocateCommandBuffer()
		cmd:Begin()
		own_cmd = true
	end

	do
		render2d.ResetState()
		local old_w, old_h = render2d.GetSize()
		render.PushCommandBuffer(cmd)
		fb:Begin()
		local old_color = {render2d.GetColor()}
		local old_blend_mode = render2d.GetBlendMode()
		render2d.SetColor(1, 1, 1, 1)
		render2d.SetBlendMode("alpha", true)
		render2d.PushSwizzleMode(render2d.GetSwizzleMode())
		scratch_size.w = width
		scratch_size.h = height
		render2d.UpdateScreenSize(scratch_size.w, scratch_size.h)
		render2d.BindPipeline()
		render2d.SetSwizzleMode(0)
		render2d.PushMatrix()
		render2d.LoadIdentity()
		render2d.Translate(padding, glyph.h + padding)
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
		render2d.UpdateScreenSize(scratch_size.w, scratch_size.h)
	end

	if own_cmd then
		cmd:End()
		render.SubmitAndWait(cmd)
	end

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

	if not glyph.texture and glyph.glyph_data and glyph.w > 0 and glyph.h > 0 then
		if not render.available or not render.target then return end

		local used_temp_fbs = {}
		glyph.texture, glyph.raster_w, glyph.raster_h = render_glyph_to_texture(self, glyph_source_font, glyph, used_temp_fbs)
		local padding = self:GetPadding()
		local atlas_w = math.max(1, math.ceil(glyph.w + padding * 2))
		local atlas_h = math.max(1, math.ceil(glyph.h + padding * 2))

		if not temp_fbs then
			for _, fb in ipairs(used_temp_fbs) do
				release_temp_fb(fb)
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
		self.chars[code] = glyph
		return
	end

	self.chars[code] = glyph
end

function META:GetChar(char)
	local data = self.chars[char]

	if data ~= nil then
		if char == 10 then
			if data then
				if data.h <= 1 then data.h = self.Size end
			else
				data = {h = self.Size}
				self.chars[10] = data
			end
		end

		return data
	end

	self.rebuild = true
	self:LoadGlyph(char)
	data = self.chars[char]

	if char == 10 then
		if data then
			if data.h <= 1 then data.h = self.Size end
		else
			data = {h = self.Size}
			self.chars[10] = data
		end
	end

	return data
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
		release_temp_fb(fb)
	end
end

function META:GetLineHeight()
	local a, d = get_ascent_descent(self)
	return (a + d)
end

function META:GetTextSizeNotCached(str)
	if not self:IsReady() then return 0, 0 end

	str = tostring(str)
	batch_load_glyphs(self, str)
	local X, Y = 0, self:GetAscent()
	local max_x = 0
	local spacing = self.Spacing
	local line_height = self:GetLineHeight()
	local i = 1
	local len = #str
	local monospace = self.Monospace
	local half_size = self.Size / 2
	local tab_mult = 4
	local chars = self.chars

	while i <= len do
		local char_code = utf8.uint32(str, i)

		if char_code == 10 then
			Y = Y + line_height + spacing

			if X > max_x then max_x = X end

			X = 0
		elseif char_code == 32 then
			X = X + half_size
		elseif char_code == 9 then
			local data = chars[32] or self:GetChar(32)

			if data then
				if monospace then
					X = X + spacing * tab_mult
				else
					X = X + (data.x_advance + spacing) * tab_mult
				end
			else
				X = X + self.Size * tab_mult
			end
		else
			local data = chars[char_code]

			if data then
				if monospace then
					X = X + spacing
				else
					X = X + data.x_advance + spacing
				end
			end
		end

		i = i + utf8.byte_length(str, i)
	end

	if max_x ~= 0 and max_x > X then X = max_x end

	return X * self.Scale.x, Y * self.Scale.y
end

function META:DrawPass(str, x, y, spacing, atlas, extra_space_advance)
	local X, Y = 0, 0
	local i = 1
	local len = #str
	local padding = self:GetPadding()
	extra_space_advance = extra_space_advance or 0

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
					render2d.PushTexture(texture)
					local uv = atlas_data.page_uv_normalized
					render2d.SetUV2(uv[1], uv[2], uv[3], uv[4])
					render2d.DrawRectf(
						x + (X + data.bitmap_left - padding) * self.Scale.x,
						y + (Y + data.bitmap_top - padding) * self.Scale.y,
						atlas_data.w * self.Scale.x,
						atlas_data.h * self.Scale.y
					)

					if self.debug then
						render2d.PushTexture(nil)
						render2d.PushColor(1, 0, 0, 0.25)
						render2d.DrawRect(
							x + (X - padding) * self.Scale.x,
							y + (Y - padding) * self.Scale.y,
							(data.x_advance + padding * 2) * self.Scale.x,
							self:GetLineHeight() * self.Scale.y
						)
						render2d.PopColor()
						render2d.PopTexture()
					end

					render2d.PopTexture()
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

function META:DrawText(str, x, y, spacing, align_x, align_y, extra_space_advance)
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

	self:DrawString(str, x, y, spacing, extra_space_advance)
end

function META:GetTextSize(str)
	if type(str) ~= "string" then str = tostring(str or "|") end

	return self:GetTextSizeNotCached(str)
end

function META:WrapString(str, max_width)
	str = tostring(str or "")
	max_width = max_width or 0
	self.wrap_string_cache = self.wrap_string_cache or {}
	local cache_key = tostring(max_width) .. "\0" .. str

	if self.wrap_string_cache[cache_key] ~= nil then
		return self.wrap_string_cache[cache_key]
	end

	local size = self:GetTextSize(str)

	if max_width > size then
		self.wrap_string_cache[cache_key] = str
		return str
	end

	local wrapped = pretext.wrap_font_text(self, str, max_width)
	self.wrap_string_cache[cache_key] = wrapped
	return wrapped
end

return META:Register()
