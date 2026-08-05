local Vec2 = import("goluwa/structs/vec2.lua")
local Framebuffer = import("goluwa/render/framebuffer.lua")
local render = import("goluwa/render/render.lua")
local objects = import("goluwa/objects/objects.lua")
local utf8 = import("goluwa/string/utf8.lua")
local event = import("goluwa/event.lua")
local FontBase = import("goluwa/render2d/fonts/base.lua")
local TextureAtlas = import("goluwa/render/texture_atlas.lua")
local META = objects.CreateTemplate("font_atlas")
META.Base = FontBase
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
	self.draw_pass_cache = nil
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

local fb_pool = {}

function META:GetTempFramebuffer(w, h, format, mip_maps, filter)
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
		fb._pool_key = key
	end

	return fb
end

function META:ReleaseTempFramebuffer(fb)
	local key = fb._pool_key
	local pool = fb_pool[key]

	if not pool then
		pool = {}
		fb_pool[key] = pool
	end

	table.insert(pool, fb)
end

function META:GetMetricGlyph(code)
	if self.chars[code] ~= nil then return self.chars[code] end

	for i = 1, #self.Fonts do
		local font = self.Fonts[i]
		font:SetSize(self.Size)
		local data = font:GetGlyph(code)

		if data then return data end
	end

	return false
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

return META:Register()
