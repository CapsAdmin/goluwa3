local Vec2 = import("goluwa/structs/vec2.lua")
local Framebuffer = import("goluwa/render/framebuffer.lua")
local render = import("goluwa/render/render.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local objects = import("goluwa/objects/objects.lua")
local utf8 = import("goluwa/string/utf8.lua")
local event = import("goluwa/event.lua")
local FontBase = import("goluwa/render2d/fonts/base.lua")
local TextureAtlas = import("goluwa/render/texture_atlas.lua")
local Texture = import("goluwa/render/texture.lua")
local glyphs = import("goluwa/render2d/glyphs.lua")

local function create_temp_pool(create_fn, key_fn)
	local pools = {}
	return {
		get = function(self, ...)
			local key = key_fn(...)
			local pool = pools[key]

			if not pool then
				pool = {}
				pools[key] = pool
			end

			local obj = table.remove(pool)

			if not obj then
				obj = create_fn(self, ...)
				obj._pool_key = key
			end

			return obj
		end,
		release = function(obj)
			local key = obj._pool_key
			local pool = pools[key]

			if not pool then
				pool = {}
				pools[key] = pool
			end

			table.insert(pool, obj)
		end,
	}
end

local fb_pool = create_temp_pool(function(self, w, h, format, mip_maps, filter)
	return Framebuffer.New{
		width = w,
		height = h,
		name = string.format(
			"render2d atlas font scratch %s %dx%d",
			tostring(self:GetName() or "unnamed"),
			w,
			h
		),
		clear_color = {0, 0, 0, 0},
		format = format,
		mip_map_levels = mip_maps and "auto" or 1,
		min_filter = filter or "linear",
		mag_filter = filter or "linear",
		wrap_s = "clamp_to_edge",
		wrap_t = "clamp_to_edge",
	}
end, function(w, h, format, mip_maps, filter)
	return w .. "_" .. h .. "_" .. format .. (
			mip_maps and
			"_t" or
			"_f"
		) .. (
			filter or
			"linear"
		)
end)
local tex_pool = create_temp_pool(function(self, w, h, format, filter)
	return Texture.New{
		width = w,
		height = h,
		format = format,
		mip_map_levels = 1,
		image = {
			usage = {"storage", "sampled", "transfer_src", "transfer_dst"},
		},
		sampler = {
			min_filter = filter or "linear",
			mag_filter = filter or "linear",
			wrap_s = "clamp_to_edge",
			wrap_t = "clamp_to_edge",
		},
	}
end, function(w, h, format, filter)
	return w .. "_" .. h .. "_" .. format .. "_" .. (filter or "linear")
end)
local META = objects.CreateTemplate("font_atlas")
META.Base = FontBase
META:GetSet("FontPath", nil, {callback = "OnFontsChanged"})
META:GetSet("Padding", 1, {callback = "OnPaddingChanged"})
META:GetSet("Spacing", 0, {callback = "ClearSizeCache"})
META:GetSet("Size", 12, {callback = "ClearSizeCache"})
META:GetSet("Scale", Vec2(1, 1), {callback = "ClearSizeCache"})
META:GetSet("Filtering", "linear", {callback = "ClearSizeCache"})
META:IsSet("Monospace", false, {callback = "ClearSizeCache"})
META:IsSet("Ready", false)
META.debug = false

function META:Initialize(font_path)
	self:SetFontPath(font_path)
	self.chars = {}
	self.rebuild = false

	if render.IsReady() then
		self:CreateAtlas()
	else
		event.AddListener("RendererReady", self, function()
			self:CreateAtlas()
			return event.destroy_tag
		end)
	end
end

function META:ClearSizeCache()
	self.text_size_cache = nil
	self.wrap_string_cache = nil
	self.draw_pass_cache = nil
	self.ascent = nil
	self.descent = nil
end

function META:OnFontsChanged()
	self:ClearSizeCache()

	if self.Ready then self:RebuildFromScratch() end

	event.Call("OnFontsChanged", self)
end

function META:DrawGlyph(glyph)
	render2d.SetTexture(nil)
	glyphs.DrawGlyph(glyph.font_path, glyph.char_code, 0, 0, self.Size)
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
		local scale = self.FontPath == "bitmap" and 1 or self.Size
		self.ascent = glyphs.GetAscent(self.FontPath) * scale
		self.descent = glyphs.GetDescent(self.FontPath) * scale
	end

	return self.ascent, self.descent
end

function META:GetAscent()
	local a = get_ascent_descent(self)
	return a
end

function META:GetDescent()
	local _, d = get_ascent_descent(self)
	return d
end

function META:GetLineHeight()
	local a, d = get_ascent_descent(self)
	return (a + d)
end

function META:Rebuild()
	self.draw_pass_cache = nil
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

function META:GetAtlasFormat()
	return "r8g8b8a8_unorm"
end

function META:CreateAtlas()
	local format = self:GetAtlasFormat()
	self.texture_atlas = TextureAtlas.New(1024, 1024, self.Filtering, format)

	for code in pairs(self.chars) do
		self.chars[code] = nil
		self:LoadGlyph(code)
	end

	self.texture_atlas:Build()
	self:SetReady(true)
end

function META:GetMetricGlyph(code)
	if self.chars[code] ~= nil then return self.chars[code] end

	if not self.FontPath then return false end

	local g = glyphs.GetGlyph(self.FontPath, code)

	if not g then return false end

	-- bitmap glyphs are already rasterized, do not scale metrics
	local scale = g.texture and 1 or self.Size
	return {
		x_advance = g.x_advance * scale,
		lsb = g.lsb * scale,
		w = g.w * scale,
		h = g.h * scale,
		x_min = g.x_min * scale,
		x_max = g.x_max * scale,
		y_min = g.y_min * scale,
		y_max = g.y_max * scale,
		bearing_x = g.x_min * scale,
		bearing_y = g.y_max * scale,
		bitmap_left = g.x_min * scale,
		bitmap_top = self:GetAscent() - (g.y_max * scale),
		glyph_data = g,
		poly = g.poly,
		font_path = self.FontPath,
		char_code = code,
	}
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

function META:GetTextSizeNotCached(str)
	if not self:IsReady() then return 0, 0 end

	str = tostring(str)
	local X, Y = 0, self:GetAscent()
	local max_x = 0
	local spacing = self.Spacing
	local line_height = self:GetLineHeight()
	local i = 1
	local len = #str
	local monospace = self.Monospace
	local half_size = self.Size / 2
	local tab_mult = self.TabWidthMultiplier or 4
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
			local data = chars[32] or self:GetMetricGlyph(32)

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
			local data = chars[char_code] or self:GetMetricGlyph(char_code)

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

function META:GetTextSize(str)
	if type(str) ~= "string" then str = tostring(str or "|") end

	self.text_size_cache = self.text_size_cache or {}
	local cached = self.text_size_cache[str]

	if cached then return cached[1], cached[2] end

	local w, h = self:GetTextSizeNotCached(str)
	self.text_size_cache[str] = {w, h}
	return w, h
end

function META:GetTempFramebuffer(w, h, format, mip_maps, filter)
	return fb_pool.get(self, w, h, format, mip_maps, filter)
end

function META:ReleaseTempFramebuffer(fb)
	fb_pool.release(fb)
end

function META:GetTempTexture(w, h, format, filter)
	return tex_pool.get(self, w, h, format, filter)
end

do
	local function glyph_has_drawable_outline(glyph)
		local glyph_data = glyph and glyph.glyph_data

		if not glyph_data then return false end

		if not glyph_data.points or #glyph_data.points == 0 then return false end

		if not glyph_data.end_pts_of_contours or #glyph_data.end_pts_of_contours == 0 then
			return false
		end

		return true
	end

	local function get_next_pow2_and_steps(n)
		local r = 1
		local steps = 0

		while r < n do
			r = r * 2
			steps = steps + 1
		end

		return r, steps
	end

	local function estimate_glyph_sdf_descriptor_slots(self, code)
		if self.chars[code] ~= nil then return 0 end

		if not self.FontPath then return 0 end

		local g = glyphs.GetGlyph(self.FontPath, code)

		if not g or not g.glyph_data or g.w <= 0 or g.h <= 0 then return 0 end

		local glyph = {
			w = g.w * self.Size,
			h = g.h * self.Size,
			glyph_data = g,
		}

		if not glyph_has_drawable_outline(glyph) then return 0 end

		local sw, sh = self:GetAtlasPadding(glyph.w, glyph.h)
		local _, steps = get_next_pow2_and_steps(math.max(sw, sh))
		return (steps + 4) * 2 + 1
	end

	function META:LoadGlyph(code, temp_fbs)
		if type(code) == "string" then code = utf8.uint32(code) end

		if self.chars[code] ~= nil then return end

		if not self.FontPath then
			self.chars[code] = false
			return
		end

		local g = glyphs.GetGlyph(self.FontPath, code)

		if not g then
			self.chars[code] = false
			return
		end

		-- bitmap glyphs are already rasterized, do not scale metrics
		local scale = g.texture and 1 or self.Size
		local glyph = {
			x_advance = g.x_advance * scale,
			lsb = g.lsb * scale,
			w = g.w * scale,
			h = g.h * scale,
			x_min = g.x_min * scale,
			x_max = g.x_max * scale,
			y_min = g.y_min * scale,
			y_max = g.y_max * scale,
			bearing_x = g.x_min * scale,
			bearing_y = g.y_max * scale,
			bitmap_left = g.x_min * scale,
			bitmap_top = self:GetAscent() - (g.y_max * scale),
			glyph_data = g,
			poly = g.poly,
			font_path = self.FontPath,
			char_code = code,
		}
		local used_temp_fbs = {}
		self:RenderGlyph(glyph, used_temp_fbs)
		self.texture_atlas:Set(code, glyph.atlas_data)
		self.chars[code] = glyph

		if not temp_fbs then
			self:Rebuild()

			for _, fb in ipairs(used_temp_fbs) do
				fb_pool.release(fb)
			end

			self.rebuild = false
		end
	end

	local JFA_DESCRIPTOR_SET_COUNT = 1024

	function META:LoadGlyphsFromString(str)
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
			local slots_needed = estimate_glyph_sdf_descriptor_slots(self, cc)
			local used_slots = self._jfa_descriptor_slot_cmd == cmd and (self._jfa_descriptor_slot or 0) or 0

			if slots_needed > 0 and used_slots + slots_needed > JFA_DESCRIPTOR_SET_COUNT then
				render.PopCommandBuffer()
				cmd:End()
				render.SubmitAndWait(cmd)
				cmd = render.GetCommandPool():AllocateCommandBuffer()
				cmd:Begin()
				render.PushCommandBuffer(cmd)
			end

			self:LoadGlyph(cc, temp_fbs)
			i = i + utf8.byte_length(str, i)
		end

		self:Rebuild()
		render.PopCommandBuffer()
		cmd:End()
		render.SubmitAndWait(cmd)
		self.rebuild = false

		for _, fb in ipairs(temp_fbs) do
			fb_pool.release(fb)
		end
	end
end

return META:Register()
