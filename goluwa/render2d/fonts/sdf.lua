--[[HOTRELOAD
	--os.execute("luajit glw test sdf_fonts")
]]
local render2d = import("goluwa/render2d/render2d.lua")
local msdf = import("goluwa/render2d/msdf.lua")
local Framebuffer = import("goluwa/render/framebuffer.lua")
local render = import("goluwa/render/render.lua")
local objects = import("goluwa/objects/objects.lua")
local utf8 = import("goluwa/string/utf8.lua")
local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
local event = import("goluwa/event.lua")
local META = objects.CreateTemplate("sdf_font")
META.Base = import("goluwa/render2d/fonts/base.lua")
META:GetSet("TabWidthMultiplier", 4)
META:IsSet("MSDF", false)
local SUPER_SAMPLING_SCALE = 4

function META.New(font_path, msdf_flag)
	local self = META:CreateObject()
	self:SetMSDF(msdf_flag)
	self:Initialize(font_path)
	return self
end

function META:GetEffectiveSpread()
	return math.max(2, math.ceil(self.Size / SUPER_SAMPLING_SCALE)) * SUPER_SAMPLING_SCALE
end

local function lerp(a, b, t)
	return {x = a.x + (b.x - a.x) * t, y = a.y + (b.y - a.y) * t}
end

local function flatten_quad(p0, c, p1, out, steps)
	steps = steps or 8

	for i = 1, steps do
		local t = i / steps
		local a = lerp(p0, c, t)
		local b = lerp(c, p1, t)
		local pt = lerp(a, b, t)
		out[#out + 1] = pt
	end
end

local function flatten_contour(raw_contour, curve_steps)
	local n = #raw_contour

	if n == 0 then return {} end

	-- normalize starting point to an on-curve point if one exists
	local start = 1

	for i = 1, n do
		if raw_contour[i].on_curve then
			start = i

			break
		end
	end

	local ordered = {}

	for i = 0, n - 1 do
		ordered[#ordered + 1] = raw_contour[((start - 1 + i) % n) + 1]
	end

	if not ordered[1].on_curve then
		local mid = lerp(ordered[n], ordered[1], 0.5)
		table.insert(ordered, 1, {x = mid.x, y = mid.y, on_curve = true})
		n = n + 1
	end

	local poly = {}
	poly[#poly + 1] = {x = ordered[1].x, y = ordered[1].y}
	local i = 2

	while i <= n + 1 do
		local cur = ordered[((i - 1) % n) + 1]

		if cur.on_curve then
			poly[#poly + 1] = {x = cur.x, y = cur.y}
			i = i + 1
		else
			local nxt = ordered[(i % n) + 1]
			local end_pt

			if nxt.on_curve then
				end_pt = {x = nxt.x, y = nxt.y}
				i = i + 2
			else
				end_pt = lerp(cur, nxt, 0.5) -- implied on-curve point
				i = i + 1
			end

			local prev = poly[#poly]
			flatten_quad(prev, cur, end_pt, poly, curve_steps)
		end
	end

	-- drop duplicate closing point if flatten produced it
	local first, last = poly[1], poly[#poly]

	if math.abs(first.x - last.x) < 1e-6 and math.abs(first.y - last.y) < 1e-6 then
		poly[#poly] = nil
	end

	return poly
end

local function extract_glyph_edges(self, glyph, curve_steps)
	local out = {}
	local start_idx = 1
	local scale1 = self.Size / glyph.units_per_em
	local spread = self:GetEffectiveSpread()
	local scale2 = spread * SUPER_SAMPLING_SCALE / 2

	for _, end_idx_0 in ipairs(glyph.glyph_data.glyph_data.end_pts_of_contours) do
		local end_idx = end_idx_0 + 1
		local contour = {}

		for i = start_idx, end_idx do
			local p = glyph.glyph_data.glyph_data.points[i]
			contour[#contour + 1] = {x = p.x, y = p.y, on_curve = p.on_curve}
		end

		local poly = flatten_contour(contour, curve_steps or 8)
		local colored = msdf.ColorPolyline(poly)

		for _, e in ipairs(colored) do
			-- Transform edge coordinates to supersampled texture space
			out[#out + 1] = {
				p0 = {
					x = ((e.p0.x * scale1) - glyph.bitmap_left) * SUPER_SAMPLING_SCALE + scale2,
					y = -((e.p0.y * scale1) - glyph.bearing_y) * SUPER_SAMPLING_SCALE + scale2,
				},
				p1 = {
					x = ((e.p1.x * scale1) - glyph.bitmap_left) * SUPER_SAMPLING_SCALE + scale2,
					y = -((e.p1.y * scale1) - glyph.bearing_y) * SUPER_SAMPLING_SCALE + scale2,
				},
				channel = e.channel,
			}
		end

		start_idx = end_idx + 1
	end

	return out
end

do
	function META:RenderGlyph(glyph)
		local debug_collect = {}
		local spread = self:GetEffectiveSpread()
		local output_w = math.ceil(glyph.w + spread)
		local output_h = math.ceil(glyph.h + spread)
		local super_w = output_w * SUPER_SAMPLING_SCALE
		local super_h = output_h * SUPER_SAMPLING_SCALE
		local mask_texture = render.ExecuteCommand(function(cmd)
			local saved_batch = render2d.SaveBatchState()
			render2d.state.runtime.batch.state:ClearPending()
			local mask_fb = Framebuffer.New{
				width = super_w,
				height = super_h,
				name = string.format(
					"render2d atlas font scratch %s %dx%d",
					tostring(self:GetName() or "unnamed"),
					super_w,
					super_h
				),
				clear_color = {0, 0, 0, 0},
				format = self:GetAtlasFormat(),
				mip_map_levels = "auto",
				min_filter = "linear",
				mag_filter = "linear",
				wrap_s = "clamp_to_edge",
				wrap_t = "clamp_to_edge",
			}
			mask_fb:Begin(cmd)
			render2d.PushBlendPreset("alpha")
			render2d.PushScreenSize(super_w, super_h)
			render2d.PushMatrix()
			render2d.LoadIdentity()
			render2d.Translate(spread * SUPER_SAMPLING_SCALE / 2, spread * SUPER_SAMPLING_SCALE / 2)
			render2d.Scale(SUPER_SAMPLING_SCALE, SUPER_SAMPLING_SCALE)
			render2d.Translatef(-glyph.bitmap_left, -glyph.bitmap_top)
			render2d.SetSDFTexelRange(1)
			self:DrawGlyph(glyph.glyph_data)
			render2d.FlushBatches("glyph_load")
			render2d.PopMatrix()
			render2d.PopScreenSize()
			render2d.PopBlendMode()
			render2d.RestoreBatchState(saved_batch)
			mask_fb:End(cmd)
			return mask_fb.color_texture
		end)

		render.ExecuteCommand(function(cmd)
			local edges = self.MSDF and extract_glyph_edges(self, glyph, 8) or nil
			local tex_final = msdf.Build(
				mask_texture,
				{
					width = output_w,
					height = output_h,
					spread = spread * SUPER_SAMPLING_SCALE,
					format = self:GetAtlasFormat(),
					filter = "linear",
					msdf = self.MSDF,
					edges = edges,
				}
			)

			if debug_collect then
				debug_collect.final = tex_final
				debug_collect.mask = mask_texture
				self:OnTextureGenerated(glyph, debug_collect)
			end

			glyph.texture = tex_final
			glyph.atlas_data = {
				w = tex_final:GetSize().x,
				h = tex_final:GetSize().y,
				texture = tex_final,
				texel_range = spread,
			}
		end)
	end
end

local DEBUG = false

function META:OnTextureGenerated(glyph, textures)
	if not DEBUG then return end

	local str = string.char(glyph.char_code)

	for name, tex in pairs(textures) do
		tex:Download():SaveAs("tmp/sdf_glyphs/" .. str .. "_" .. name .. ".png")
	end
end

function META:GetAtlasPadding(w, h)
	local spread = self:GetEffectiveSpread()
	return (w + spread) * SUPER_SAMPLING_SCALE, (h + spread) * SUPER_SAMPLING_SCALE
end

local function glyph_fn(self, data, X, Y, entries)
	local spread = self:GetEffectiveSpread()
	local atlas_data = data.atlas_data

	if atlas_data and atlas_data.page then
		entries[#entries + 1] = {
			texture = atlas_data.page.texture,
			uv = atlas_data.page_uv_normalized,
			x = (X + data.bitmap_left - spread / 2) * self.Scale.x,
			y = (Y + data.bitmap_top - spread / 2) * self.Scale.y,
			w = atlas_data.w * self.Scale.x,
			h = atlas_data.h * self.Scale.y,
			texel_range = atlas_data.texel_range,
		}
	end
end

local function build_draw_pass_layout(self, str, spacing, extra_space_advance)
	local spread = self:GetEffectiveSpread()
	local entries = self:BuildLayout(str, spacing, extra_space_advance, glyph_fn)
	return {
		entries = entries,
		margin = spread * self.Scale.x,
	}
end

local function get_draw_pass_layout(self, str, spacing, extra_space_advance)
	local atlas_cache = self.draw_pass_cache

	if not atlas_cache then
		atlas_cache = {}
		self.draw_pass_cache = atlas_cache
	end

	local spacing_cache = atlas_cache[spacing]

	if not spacing_cache then
		spacing_cache = {}
		atlas_cache[spacing] = spacing_cache
	end

	local param_cache = spacing_cache[extra_space_advance]

	if not param_cache then
		param_cache = {}
		spacing_cache[extra_space_advance] = param_cache
	end

	local cached = param_cache[str]

	if cached then return cached end

	cached = build_draw_pass_layout(self, str, spacing, extra_space_advance)
	param_cache[str] = cached
	return cached
end

local render2d_SetTexture = render2d.SetTexture
local render2d_DrawRectUV2f = render2d.DrawRectUV2f
local render2d_PushColor = render2d.PushColor
local render2d_DrawRect = render2d.DrawRect
local render2d_PopColor = render2d.PopColor

function META:DrawString(str, x, y, spacing, extra_space_advance)
	str = tostring(str)
	self:LoadGlyphsFromString(str)
	spacing = spacing or self.Spacing
	extra_space_advance = extra_space_advance or 0
	render2d.PushUV()
	render2d.PushSDFTexture()
	--render2d.PushTexture()
	render2d.PushSDFTexelRange(0)

	if self.MSDF then render2d.PushMSDFEnabled(true) end

	local last_texture = nil
	local last_texel_range = nil
	local layout = get_draw_pass_layout(self, str, spacing, extra_space_advance or 0)

	if layout.entries[1] then
		render2d.SetSDFTexture(layout.entries[1].texture)
		render2d.SetSDFTexelRange(layout.entries[1].texel_range)
	end

	for _, entry in ipairs(layout.entries) do
		if entry.texture ~= last_texture then
			render2d.SetSDFTexture(entry.texture)
			last_texture = entry.texture
		end

		if entry.texel_range ~= last_texel_range then
			render2d.SetSDFTexelRange(entry.texel_range)
			last_texel_range = entry.texel_range
		end

		render2d_DrawRectUV2f(
			x + entry.x,
			y + entry.y,
			entry.w,
			entry.h,
			entry.uv[1],
			entry.uv[4],
			entry.uv[3],
			entry.uv[2],
			nil,
			nil,
			nil,
			layout.margin
		)
	end

	if self.MSDF then render2d.PopMSDFEnabled() end

	--render2d.PopTexture()
	render2d.PopSDFTexelRange()
	render2d.PopSDFTexture()
	render2d.PopUV()
end

return META:Register()
