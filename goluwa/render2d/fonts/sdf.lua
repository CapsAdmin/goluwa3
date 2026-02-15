--[[HOTRELOAD
	os.execute("luajit glw test sdf_fonts")
]]
local Vec2 = require("structs.vec2")
local render2d = require("render2d.render2d")
local Framebuffer = require("render.framebuffer")
local render = require("render.render")
local prototype = require("prototype")
local utf8 = require("utf8")
local event = require("event")
local TextureAtlas = require("render.texture_atlas")
local EasyPipeline = require("render.easy_pipeline")
local META = prototype.CreateTemplate("sdf_font")
META.IsFont = true
META:GetSet("Fonts", {}, {callback = "OnFontsChanged"})
META:GetSet("Spread", 16, {callback = "ClearSizeCache"})
META:GetSet("Padding", 2, {callback = "OnPaddingChanged"})
META:GetSet("Spacing", 0, {callback = "ClearSizeCache"})
META:GetSet("Size", 12, {callback = "ClearSizeCache"})
META:GetSet("Scale", Vec2(1, 1), {callback = "ClearSizeCache"})
META:GetSet("Filtering", "linear", {callback = "ClearSizeCache"})

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

META:IsSet("Monospace", false, {callback = "ClearSizeCache"})
META:IsSet("Ready", false)
META.debug = false

function META:__copy()
	return self
end

local SUPER_SAMPLING_SCALE = 4

function META:ClearSizeCache()
	self.text_size_cache = nil
	self.wrap_string_cache = nil
	self.ascent = nil
	self.descent = nil
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

META:GetSet("LoadSpeed", 10)
META:GetSet("TabWidthMultiplier", 4)
META:GetSet("Flags")

function META:GetAtlasFormat()
	return "r16g16b16a16_unorm"
end

function META:GetJFAPipelines()
	if self.jfa_pipelines then return self.jfa_pipelines end

	self.jfa_pipelines = {
		init = EasyPipeline.FragmentOnly(
			{
				color_format = {{"r32g32_sfloat", {"rg", "rg"}}},
				block = {
					{
						"tex_idx",
						"int",
						function(p, b, k)
							b[k] = p:GetTextureIndex(p.current_jfa_tex)
						end,
					},
					{
						"mode",
						"int",
						function(p, b, k)
							b[k] = p.current_jfa_mode
						end,
					},
					{
						"size",
						"vec2",
						function(p, b, k)
							b[k][0] = p.current_jfa_size.x
							b[k][1] = p.current_jfa_size.y
						end,
					},
				},
				shader = [[
					layout(location = 0) in vec2 in_uv;
					void main() {
						vec4 tex = texture(TEXTURE(pc.fragment.tex_idx), in_uv);
						float mask = max(tex.r, tex.a);
						// Use coverage-aware seeding: pixels with any partial
						// coverage are seeds, which captures the anti-aliased edge
						bool is_seed = (pc.fragment.mode == 0) ? (mask > 0.02) : (mask < 0.98);
						if (is_seed) {
							set_rg(in_uv);
						} else {
							set_rg(vec2(-1.0));
						}
					}
				]],
			}
		),
		step = EasyPipeline.FragmentOnly(
			{
				color_format = {{"r32g32_sfloat", {"rg", "rg"}}},
				block = {
					{
						"tex_idx",
						"int",
						function(p, b, k)
							b[k] = p:GetTextureIndex(p.current_jfa_tex)
						end,
					},
					{
						"step_size",
						"float",
						function(p, b, k)
							b[k] = p.current_jfa_step
						end,
					},
					{
						"size",
						"vec2",
						function(p, b, k)
							b[k][0] = p.current_jfa_size.x
							b[k][1] = p.current_jfa_size.y
						end,
					},
				},
				shader = [[
					layout(location = 0) in vec2 in_uv;
					void main() {
						vec2 best_seed = texture(TEXTURE(pc.fragment.tex_idx), in_uv).rg;
						float best_dist = (best_seed.x < 0.0) ? 1e10 : length((best_seed - in_uv) * pc.fragment.size);
						
						for (int y = -1; y <= 1; y++) {
							for (int x = -1; x <= 1; x++) {
								if (x == 0 && y == 0) continue;
								vec2 sample_uv = in_uv + vec2(float(x), float(y)) * pc.fragment.step_size / pc.fragment.size;
								vec2 seed = texture(TEXTURE(pc.fragment.tex_idx), sample_uv).rg;
								if (seed.x >= 0.0) {
									float dist = length((seed - in_uv) * pc.fragment.size);
									if (dist < best_dist) {
										best_dist = dist;
										best_seed = seed;
									}
								}
							}
						}
						set_rg(best_seed);
					}
				]],
			}
		),
		final = EasyPipeline.FragmentOnly(
			{
				color_format = {{"r32_sfloat", {"r", "r"}}},
				block = {
					{
						"tex_idx",
						"int",
						function(p, b, k)
							b[k] = p:GetTextureIndex(p.current_jfa_tex)
						end,
					},
					{
						"size",
						"vec2",
						function(p, b, k)
							b[k][0] = p.current_jfa_size.x
							b[k][1] = p.current_jfa_size.y
						end,
					},
					{
						"max_dist",
						"float",
						function(p, b, k)
							b[k] = p.current_jfa_max_dist
						end,
					},
				},
				shader = [[
					layout(location = 0) in vec2 in_uv;
					void main() {
						vec2 seed = texture(TEXTURE(pc.fragment.tex_idx), in_uv).rg;
						float dist = (seed.x < 0.0) ? pc.fragment.max_dist : length((seed - in_uv) * pc.fragment.size);
						set_r(dist);
					}
				]],
			}
		),
		combine = EasyPipeline.FragmentOnly(
			{
				color_format = {{self:GetAtlasFormat(), {"rgba", "rgba"}}},
				block = {
					{
						"dist_on_idx",
						"int",
						function(p, b, k)
							b[k] = p:GetTextureIndex(p.current_jfa_dist_on)
						end,
					},
					{
						"dist_off_idx",
						"int",
						function(p, b, k)
							b[k] = p:GetTextureIndex(p.current_jfa_dist_off)
						end,
					},
					{
						"mask_idx",
						"int",
						function(p, b, k)
							b[k] = p:GetTextureIndex(p.current_jfa_mask_tex)
						end,
					},
					{
						"max_dist",
						"float",
						function(p, b, k)
							b[k] = p.current_jfa_max_dist
						end,
					},
				},
				shader = [[
					layout(location = 0) in vec2 in_uv;
					void main() {
						float d_on = texture(TEXTURE(pc.fragment.dist_on_idx), in_uv).r;
						float d_off = texture(TEXTURE(pc.fragment.dist_off_idx), in_uv).r;

						// Use the original anti-aliased mask to refine the distance
						// at glyph boundaries for sub-pixel accuracy
						vec4 mask_sample = texture(TEXTURE(pc.fragment.mask_idx), in_uv);
						float coverage = max(mask_sample.r, mask_sample.a);

						float dist = d_off - d_on;

						// Near the edge (within ~1.5 supersampled pixels), blend in
						// a sub-pixel correction derived from the AA coverage.
						// coverage 0.5 = exactly on the edge = dist should be 0.
						float aa_offset = (coverage - 0.5);
						float edge_weight = smoothstep(2.0, 0.0, abs(dist));
						dist = mix(dist, -aa_offset, edge_weight);

						float norm_dist = clamp(dist / (pc.fragment.max_dist * 2.0) + 0.5, 0.0, 1.0);
						set_rgba(vec4(norm_dist, norm_dist, norm_dist, 1.0));
					}
				]],
			}
		),
	}
	return self.jfa_pipelines
end

do
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

	function META.New(fonts, spread)
		if type(fonts) == "table" and fonts.IsFont then fonts = {fonts} end

		local self = META:CreateObject()
		self.tr = debug.traceback()
		self:SetFonts(fonts)
		self:SetSpread(spread or 16)
		self.chars = {}
		self.rebuild = false

		if render.target then
			create_atlas(self)
		else
			event.AddListener("RendererReady", self, function()
				create_atlas(self)
				return event.destroy_tag
			end)
		end

		return self
	end
end

function META:GetAscent()
	local a, d = get_ascent_descent(self)
	return a
end

function META:GetDescent()
	local a, d = get_ascent_descent(self)
	return d
end

function META:Rebuild(cmd)
	self.texture_atlas:Build(cmd)
end

function META:RebuildFromScratch(cmd)
	if not self.texture_atlas then return end

	-- Clear all cached glyphs
	local codes_to_reload = {}

	for code in pairs(self.chars) do
		table.insert(codes_to_reload, code)
		self.chars[code] = nil
	end

	-- Reload all glyphs
	for _, code in ipairs(codes_to_reload) do
		self:LoadGlyph(code, cmd)
	end

	-- Rebuild the atlas
	self:Rebuild(cmd)
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
		fb = Framebuffer.New(
			{
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
		)
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

function META:GenerateSDF(cmd, mask_tex, sw, sh, target_w, target_h, temp_fbs)
	local p = self:GetJFAPipelines()
	local size = Vec2(sw, sh)
	local max_dim = math.max(sw, sh)

	local function get_next_pow2(n)
		local r = 1

		while r < n do
			r = r * 2
		end

		return r
	end

	local p2 = get_next_pow2(max_dim)
	local fb_a = get_temp_fb(sw, sh, "r32g32_sfloat", false, "nearest")
	local fb_b = get_temp_fb(sw, sh, "r32g32_sfloat", false, "nearest")
	local fb_dist_on = get_temp_fb(sw, sh, "r32_sfloat", false, "linear")
	local fb_dist_off = get_temp_fb(sw, sh, "r32_sfloat", false, "linear")
	table.insert(temp_fbs, fb_a)
	table.insert(temp_fbs, fb_b)
	table.insert(temp_fbs, fb_dist_on)
	table.insert(temp_fbs, fb_dist_off)
	-- Set shared properties on relevant pipelines
	p.init.current_jfa_size = size
	p.step.current_jfa_size = size
	p.final.current_jfa_size = size
	-- Ensure enough distance range for smooth blur. Use at least 8 output-space
	-- pixels so that shadows/outlines have room to fade, even with small spread.
	local max_dist = math.max(8, self:GetSpread()) * SUPER_SAMPLING_SCALE
	p.final.current_jfa_max_dist = max_dist
	p.combine.current_jfa_max_dist = max_dist

	local function run_jfa(mode, out_fb)
		p.init.current_jfa_tex = mask_tex
		p.init.current_jfa_mode = mode
		p.init:Draw(cmd, fb_a)
		local current_fb = fb_a
		local next_fb = fb_b
		local step = p2 / 2

		while step >= 1 do
			p.step.current_jfa_tex = current_fb.color_texture
			p.step.current_jfa_step = step
			p.step:Draw(cmd, next_fb)
			current_fb, next_fb = next_fb, current_fb
			step = math.floor(step / 2)
		end

		-- Extra passes at step 1 to fix precision artifacts and "wiggling" spines
		for i = 1, 2 do
			p.step.current_jfa_tex = current_fb.color_texture
			p.step.current_jfa_step = 1
			p.step:Draw(cmd, next_fb)
			current_fb, next_fb = next_fb, current_fb
		end

		p.final.current_jfa_tex = current_fb.color_texture
		p.final:Draw(cmd, out_fb)
	end

	run_jfa(0, fb_dist_on) -- Distance to ON pixels
	run_jfa(1, fb_dist_off) -- Distance to OFF pixels
	local fb_final = get_temp_fb(target_w, target_h, self:GetAtlasFormat(), false)
	table.insert(temp_fbs, fb_final)
	p.combine.current_jfa_dist_on = fb_dist_on.color_texture
	p.combine.current_jfa_dist_off = fb_dist_off.color_texture
	p.combine.current_jfa_mask_tex = mask_tex
	p.combine:Draw(cmd, fb_final)
	return fb_final.color_texture
end

function META:LoadGlyph(code, parent_cmd, temp_fbs)
	-- Convert string to character code if needed
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
		if not render.available or not render.target then
			-- Renderer not ready, don't cache yet so we can try again later
			return
		end

		local scale = SUPER_SAMPLING_SCALE
		local spread = self:GetSpread()
		local sw = (glyph.w + spread * 2) * scale
		local sh = (glyph.h + spread * 2) * scale
		local used_temp_fbs = {}
		local format = self:GetAtlasFormat()
		local fb_ss = get_temp_fb(sw, sh, format, true)
		table.insert(used_temp_fbs, fb_ss)
		local own_cmd = false
		local cmd = parent_cmd

		if not cmd then
			cmd = render.GetCommandPool():AllocateCommandBuffer()
			cmd:Begin()
			own_cmd = true
		end

		do
			render2d.ResetState()
			local old_cmd = render2d.cmd
			local old_w, old_h = render2d.GetSize()
			fb_ss:Begin(cmd)
			render2d.cmd = cmd
			render2d.PushColorFormat(fb_ss.color_texture.format)
			render2d.PushSamples("1")
			local old_color = {render2d.GetColor()}
			render2d.SetColor(1, 1, 1, 1)
			local old_blend_mode = render2d.GetBlendMode()
			render2d.SetBlendMode("alpha", true)
			render2d.PushSwizzleMode(render2d.GetSwizzleMode())
			scratch_size.w = sw
			scratch_size.h = sh
			render2d.UpdateScreenSize(scratch_size)
			render2d.pipeline:Bind(render2d.cmd, render.GetCurrentFrame())
			render2d.SetSwizzleMode(0)
			render2d.PushMatrix()
			render2d.LoadIdentity()
			-- Flip coordinates so font (Y-down) renders right-side up in Y-up framebuffer
			render2d.Translate(spread * scale, (glyph.h + spread) * scale)
			render2d.Scale(scale, -scale)
			-- Shift glyph to be at (0, 0) in the padded area
			render2d.Translatef(-glyph.bitmap_left, -glyph.bitmap_top)
			glyph_source_font:DrawGlyph(glyph.glyph_data)
			render2d.PopMatrix()
			render2d.PopSwizzleMode()
			render2d.SetBlendMode(old_blend_mode, true)
			render2d.SetColor(unpack(old_color))
			render2d.PopSamples()
			render2d.PopColorFormat()
			fb_ss:End(cmd)
			render2d.cmd = old_cmd
			scratch_size.w = old_w
			scratch_size.h = old_h
			render2d.UpdateScreenSize(scratch_size)
		end

		glyph.texture = self:GenerateSDF(
			cmd,
			fb_ss.color_texture,
			sw,
			sh,
			glyph.w + spread * 2,
			glyph.h + spread * 2,
			used_temp_fbs
		)

		if own_cmd then
			self.texture_atlas:Insert(
				code,
				{
					w = glyph.w + self:GetSpread() * 2,
					h = glyph.h + self:GetSpread() * 2,
					texture = glyph.texture,
					flip_y = glyph.flip_y,
				}
			)
			self.chars[code] = glyph
			self:Rebuild(cmd)
			cmd:End()
			render.SubmitAndWait(cmd)

			for _, fb in ipairs(used_temp_fbs) do
				release_temp_fb(fb)
			end

			self.rebuild = false
			return
		elseif temp_fbs then
			for _, fb in ipairs(used_temp_fbs) do
				table.insert(temp_fbs, fb)
			end
		end
	end

	self.texture_atlas:Insert(
		code,
		{
			w = glyph.w + self:GetSpread() * 2,
			h = glyph.h + self:GetSpread() * 2,
			texture = glyph.texture,
			flip_y = glyph.flip_y,
		}
	)
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

	-- Found first new glyph, start batch loading from here
	local cmd = render.GetCommandPool():AllocateCommandBuffer()
	cmd:Begin()
	local temp_fbs = {}

	-- Load from current position (first new glyph) onwards
	while i <= len do
		local cc = utf8.uint32(str, i)
		self:LoadGlyph(cc, cmd, temp_fbs)
		i = i + utf8.byte_length(str, i)
	end

	self:Rebuild(cmd)
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
	local tab_mult = self.TabWidthMultiplier
	local chars = self.chars

	while i <= len do
		local char_code = utf8.uint32(str, i)

		if char_code == 10 then -- \n
			Y = Y + line_height + spacing

			if X > max_x then max_x = X end

			X = 0
		elseif char_code == 32 then -- space
			X = X + half_size
		elseif char_code == 9 then -- \t
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

function META:DrawPass(str, x, y, spacing, atlas)
	local X, Y = 0, 0
	local i = 1
	local len = #str
	local last_texture

	while i <= len do
		local char_code = utf8.uint32(str, i)

		if char_code == 10 then -- \n
			X = 0
			Y = Y + self:GetLineHeight() + spacing
		elseif char_code == 32 then -- space
			X = X + self.Size / 2
		elseif char_code == 9 then -- \t
			local data = self.chars[32] or self:GetChar(32)

			if data then
				if self.Monospace then
					X = X + spacing * self.TabWidthMultiplier
				else
					X = X + (data.x_advance + spacing) * self.TabWidthMultiplier
				end
			else
				X = X + self.Size * self.TabWidthMultiplier
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
						x + (X + data.bitmap_left - self:GetSpread()) * self.Scale.x,
						y + (Y + data.bitmap_top - self:GetSpread()) * self.Scale.y,
						atlas_data.w * self.Scale.x,
						atlas_data.h * self.Scale.y,
						nil,
						nil,
						nil,
						self:GetSpread() * self.Scale.x
					)

					if self.debug then
						render2d.PushTexture(nil)
						render2d.PushColor(1, 0, 0, 0.25)
						render2d.DrawRect(
							x + (X - self:GetSpread()) * self.Scale.x,
							y + (Y - self:GetSpread()) * self.Scale.y,
							(data.x_advance + self:GetSpread() * 2) * self.Scale.x,
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

function META:DrawString(str, x, y, spacing)
	if not self:IsReady() then return end

	str = tostring(str)
	batch_load_glyphs(self, str)
	spacing = spacing or self.Spacing
	render2d.PushUV()
	render2d.PushSDFMode(true)
	render2d.SetSubpixelMode("vrgb")
	render2d.SetSubpixelAmount(0.1)
	self:DrawPass(str, x, y, spacing, self.texture_atlas)
	render2d.SetSubpixelMode("none")
	render2d.PopSDFMode()
	render2d.PopUV()
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

	function META:GetTextSize(str)
		if type(str) ~= "string" then str = tostring(str or "|") end

		return self:GetTextSizeNotCached(str)
	end

	do -- text wrap
		local function wrap(self, str, max_width)
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

		function META:WrapString(str, max_width)
			str = tostring(str or "")
			local size = self:GetTextSize(str)

			--print(size, max_width)
			--if max_width < size then return list.concat(str:split(""), "\n") end
			if max_width > size then return str end

			local res = wrap(self, str, max_width)
			return res
		end
	end
end

return META:Register()
