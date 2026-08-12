local Vec2 = import("goluwa/structs/vec2.lua")
local Framebuffer = import("goluwa/render/framebuffer.lua")
local render = import("goluwa/render/render.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local objects = import("goluwa/objects/objects.lua")
local pretext = import("goluwa/pretext/init.lua")
local utf8 = import("goluwa/string/utf8.lua")
local event = import("goluwa/event.lua")
local TextureAtlas = import("goluwa/render/texture_atlas.lua")
local Texture = import("goluwa/render/texture.lua")
local glyphs = import("goluwa/render2d/glyphs.lua")
local file_path = import("goluwa/filesystem/path.lua")

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
META.IsFont = true
META:GetSet("FontPath", nil, {callback = "OnFontsChanged"})
META:GetSet("Padding", 0, {callback = "OnPaddingChanged"})
META:GetSet("Spacing", 0, {callback = "ClearSizeCache"})
META:GetSet("Size", 12, {callback = "ClearSizeCache"})
META:GetSet("Scale", Vec2(1, 1), {callback = "ClearSizeCache"})
META:GetSet("Filtering", "linear", {callback = "ClearSizeCache"})
META:IsSet("Monospace", false, {callback = "ClearSizeCache"})
META:GetSet("Path", "default")

function META:__copy()
	return self
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

function META:GetSpaceAdvance()
	local width = select(1, self:GetTextSize(" "))

	if width == 0 then
		width = select(1, self:GetTextSize("| |")) - select(1, self:GetTextSize("||"))
	end

	return width
end

function META:GetTabAdvance(space_width, tab_size, current_width)
	if self.GetTabWidth then
		return self:GetTabWidth(space_width, tab_size, current_width)
	end

	return (space_width or self:GetSpaceAdvance()) * (tab_size or 4)
end

function META:GetGlyphAdvance(char)
	return select(1, self:GetTextSize(char))
end

function META:MeasureText(str)
	return self:GetTextSize(str)
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

function META:Initialize(font_path)
	self:SetFontPath(font_path)
	self.chars = {}
	self.rebuild = false
	local format = self:GetAtlasFormat()
	self.texture_atlas = TextureAtlas.New(1024, 1024, self.Filtering, format)
	local type = self.Type

	if type == "sdf_font" then if self:IsMSDF() then type = "msdf_font" end end

	self.texture_atlas:SetName(
		type .. " - " .. file_path.RemoveExtensionFromPath(file_path.GetFileNameFromPath(font_path))
	)

	for code in pairs(self.chars) do
		self.chars[code] = nil
		self:LoadGlyph(code)
	end

	self.texture_atlas:Build()
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
	self:RebuildFromScratch()
	event.Call("OnFontsChanged", self)
end

function META:DrawGlyph(glyph)
	render2d.SetTexture(nil)
	render2d.SetSDFTexture(nil)
	render2d.SetColor(1, 1, 1, 1)
	glyphs.DrawGlyph(glyph.font_path, glyph.char_code, 0, 0, self.Size)
end

function META:OnPaddingChanged()
	if self.texture_atlas then
		self.texture_atlas:SetPadding(self.Padding)
		self:ClearSizeCache()
		self:RebuildFromScratch()
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

	for code in pairs(self.chars) do
		self.chars[code] = nil
		self:LoadGlyph(code)
	end

	self:Rebuild()
end

function META:GetAtlasFormat()
	return "r8g8b8a8_unorm"
end

local function build_glyph_metrics(self, g, code)
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
		units_per_em = g.units_per_em,
	}
end

function META:GetMetricGlyph(code)
	if self.chars[code] ~= nil then return self.chars[code] end

	if not self.FontPath then return false end

	local g = glyphs.GetGlyph(self.FontPath, code)

	if not g then return false end

	return build_glyph_metrics(self, g, code)
end

function META:GetTextSizeNotCached(str)
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

function META:StartCollectTempResources()
	self.temp_textures = {}
	self.temp_framebuffers = {}
end

function META:IsCollectingTempResources()
	return self.temp_textures ~= nil
end

function META:ReleaseTempResources()
	for i, v in ipairs(self.temp_textures) do

	--tex_pool.release(v)
	end

	for i, v in ipairs(self.temp_framebuffers) do
		fb_pool.release(v)
	end

	self.temp_textures = nil
	self.temp_framebuffers = nil
end

function META:GetTempFramebuffer(w, h, format, mip_maps, filter)
	local fb = fb_pool.get(self, w, h, format, mip_maps, filter)

	if self.temp_framebuffers then table.insert(self.temp_framebuffers, fb) end

	return fb
end

function META:GetTempTexture(w, h, format, filter)
	local tex = assert(tex_pool.get(self, w, h, format, filter))

	if self.temp_textures then table.insert(self.temp_textures, tex) end

	return tex
end

function META:BuildLayout(str, spacing, extra_space_advance, glyph_fn)
	local X, Y = 0, 0
	local i = 1
	local line_height = self:GetLineHeight()
	local monospace = self.Monospace
	local tab_mult = self.TabWidthMultiplier or 4
	local half_size = self.Size / 2
	local entries = {}

	while i <= #str do
		local byte = string.byte(str, i)
		local char_code
		local char_size

		if byte < 128 then
			char_code = byte
			char_size = 1
		else
			char_code = utf8.uint32(str, i)
			char_size = utf8.byte_length(str, i)
		end

		if char_code == 10 then
			X = 0
			Y = Y + line_height + spacing
		elseif char_code == 32 then
			X = X + half_size + extra_space_advance
		elseif char_code == 9 then
			local space_data = self.chars[32] or self:GetMetricGlyph(32)

			if monospace then
				X = X + spacing * tab_mult
			elseif space_data then
				X = X + (space_data.x_advance + spacing) * tab_mult
			else
				X = X + self.Size * tab_mult
			end
		else
			local data = self.chars[char_code] or self:GetMetricGlyph(char_code)

			if data then
				glyph_fn(self, data, X, Y, entries)

				if monospace then
					X = X + spacing
				else
					X = X + data.x_advance + spacing
				end
			else
				X = X + self.Size + spacing
			end
		end

		i = i + char_size
	end

	return entries
end

function META:LoadGlyph(code)
	if type(code) == "string" then code = utf8.uint32(code) end

	if self.chars[code] ~= nil then return self.chars[code] end

	if not self.FontPath then
		self.chars[code] = false
		return
	end

	local g = glyphs.GetGlyph(self.FontPath, code)

	if not g or not g.is_visual then
		self.chars[code] = false
		return
	end

	-- bitmap glyphs are already rasterized, do not scale metrics
	local glyph = build_glyph_metrics(self, g, code)
	self.chars[code] = glyph
	local batched = self:IsCollectingTempResources()

	if not batched then self:StartCollectTempResources() end

	self:RenderGlyph(glyph)
	self.texture_atlas:Set(code, glyph.atlas_data)

	if not batched then
		self:Rebuild()
		self:ReleaseTempResources()
		self.rebuild = false
	end

	return glyph
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

return META:Register()
