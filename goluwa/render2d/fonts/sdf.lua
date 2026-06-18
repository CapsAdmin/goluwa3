--[[HOTRELOAD
	--os.execute("luajit glw test sdf_fonts")
]]
local Vec2 = import("goluwa/structs/vec2.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local Framebuffer = import("goluwa/render/framebuffer.lua")
local render = import("goluwa/render/render.lua")
local Texture = import("goluwa/render/texture.lua")
local prototype = import("goluwa/prototype.lua")
local utf8 = import("goluwa/string/utf8.lua")
local event = import("goluwa/event.lua")
local TextureAtlas = import("goluwa/render/texture_atlas.lua")
local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
local pretext = import("goluwa/pretext/init.lua")
-- Debug mode: enables texture readback assertions after each JFA pass
local DEBUG = false

local function debug_assert_sdf_texture(tex, name, min_valid, min_valid_count, desc)
	if not DEBUG or not tex then return end

	local cmd = render.GetCommandBuffer()

	if cmd then
		cmd:End()
		render.SubmitAndWait(cmd)
		cmd:Begin()
		render.PushCommandBuffer(cmd)
	end

	-- Submit any pending command buffer so the texture is written before we read it back
	local data = tex:Download()

	if not data then
		error(string.format("SDF debug [%s]: failed to download texture", name), 0)
	end

	local w, h = tex:GetWidth(), tex:GetHeight()
	local valid_count = 0
	local invalid_count = 0
	local min_val = 1e10
	local max_val = -1e10

	data:ForEachPixel(function(x, y, r, g, b, a)
		local is_valid = (r >= min_valid and g >= min_valid) or (a >= min_valid)

		if is_valid then
			valid_count = valid_count + 1
		else
			invalid_count = invalid_count + 1
		end

		local v = math.min(math.min(r, g), math.min(b, a))

		if v < min_val then min_val = v end

		v = math.max(math.max(r, g), math.max(b, a))

		if v > max_val then max_val = v end
	end)

	if valid_count < min_valid_count then
		error(
			string.format(
				"SDF debug [%s] FAILED: %s\n  valid=%d invalid=%d range=[%.4f, %.4f]\n  texture=%dx%d format=%s",
				name,
				desc,
				valid_count,
				invalid_count,
				min_val / 255,
				max_val / 255,
				w,
				h,
				tex.format
			),
			0
		)
	end

	print(
		string.format(
			"SDF debug [%s] OK: %s valid=%d invalid=%d range=[%.4f, %.4f]",
			name,
			desc,
			valid_count,
			invalid_count,
			min_val / 255,
			max_val / 255
		)
	)
end

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
local JFA_DESCRIPTOR_SET_COUNT = 256

function META:ClearSizeCache()
	self.text_size_cache = nil
	self.wrap_string_cache = nil
	self.draw_pass_cache = nil
	self.metric_chars = nil
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

local function get_sdf_storage_format(target_format)
	return "r8g8b8a8_unorm"
end

META:GetSet("LoadSpeed", 10)
META:GetSet("TabWidthMultiplier", 4)
META:GetSet("Flags")

function META:GetEffectiveSpread()
	local spread = math.max(1, self:GetSpread())
	local size_limited = math.max(2, math.floor(self:GetSize() * 0.4 + 0.5))
	return math.min(spread, size_limited)
end

function META:GetAtlasFormat()
	return get_sdf_storage_format(render.target:GetColorFormat())
end

local shared_jfa_pipelines = {}

function META:GetJFAPipelines()
	if self.jfa_pipelines then return self.jfa_pipelines end

	local atlas_format = self:GetAtlasFormat()
	local shared = shared_jfa_pipelines[atlas_format]

	if shared then
		self.jfa_pipelines = shared
		return shared
	end

	self.jfa_pipelines = {
		init = EasyPipeline.Compute{
			DescriptorSetCount = JFA_DESCRIPTOR_SET_COUNT,
			LocalSize = {x = 8, y = 8, z = 1},
			descriptor_sets = {
				{
					type = "storage_image",
					binding_index = 0,
					stageFlags = "compute",
					set_index = 0,
				},
				{
					type = "combined_image_sampler",
					binding_index = 1,
					stageFlags = "compute",
					set_index = 0,
				},
			},
			block = {
				{"mode", "int"},
			},
			write = function(self, block)
				block.mode = self.current_jfa_mode
				return block
			end,
			shader = [[
					layout(set = 0, binding = 0, rg32f) uniform writeonly image2D out_seed;
					layout(set = 0, binding = 1) uniform sampler2D mask_tex;
					void main() {
						ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
						ivec2 size = imageSize(out_seed);
						if (pos.x >= size.x || pos.y >= size.y) return;
						vec2 uv = (vec2(pos) + vec2(0.5)) / vec2(size);
						vec4 tex = texture(mask_tex, uv);
						float mask = max(tex.r, tex.a);
						vec2 seed = (compute.mode == 0) ? (mask > 0.02 ? vec2(pos) : vec2(-1.0)) : (mask < 0.98 ? vec2(pos) : vec2(-1.0));
						imageStore(out_seed, pos, vec4(seed, 0.0, 0.0));
					}
				]],
		},
		step = EasyPipeline.Compute{
			DescriptorSetCount = JFA_DESCRIPTOR_SET_COUNT,
			LocalSize = {x = 8, y = 8, z = 1},
			descriptor_sets = {
				{
					type = "storage_image",
					binding_index = 0,
					stageFlags = "compute",
					set_index = 0,
				},
				{
					type = "combined_image_sampler",
					binding_index = 1,
					stageFlags = "compute",
					set_index = 0,
				},
			},
			block = {
				{"step_size", "int"},
			},
			write = function(self, block)
				block.step_size = self.current_jfa_step
				return block
			end,
			shader = [[
					layout(set = 0, binding = 0, rg32f) uniform writeonly image2D out_seed;
					layout(set = 0, binding = 1) uniform sampler2D in_seed;
					void main() {
						ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
						ivec2 size = imageSize(out_seed);
						if (pos.x >= size.x || pos.y >= size.y) return;
						vec2 best_seed = texelFetch(in_seed, pos, 0).rg;
						float best_dist = (best_seed.x < 0.0) ? 1e10 : length(best_seed - vec2(pos));

						for (int y = -1; y <= 1; y++) {
							for (int x = -1; x <= 1; x++) {
								if (x == 0 && y == 0) continue;
								ivec2 sample_pos = clamp(pos + ivec2(x, y) * compute.step_size, ivec2(0), size - ivec2(1));
								vec2 seed = texelFetch(in_seed, sample_pos, 0).rg;
								if (seed.x >= 0.0) {
									float dist = length(seed - vec2(pos));
									if (dist < best_dist) {
										best_dist = dist;
										best_seed = seed;
									}
								}
							}
						}

						imageStore(out_seed, pos, vec4(best_seed, 0.0, 0.0));
					}
				]],
		},
		final = EasyPipeline.Compute{
			DescriptorSetCount = JFA_DESCRIPTOR_SET_COUNT,
			LocalSize = {x = 8, y = 8, z = 1},
			descriptor_sets = {
				{
					type = "storage_image",
					binding_index = 0,
					stageFlags = "compute",
					set_index = 0,
				},
				{
					type = "combined_image_sampler",
					binding_index = 1,
					stageFlags = "compute",
					set_index = 0,
				},
			},
			block = {
				{"max_dist", "float"},
			},
			write = function(self, block)
				block.max_dist = self.current_jfa_max_dist
				return block
			end,
			shader = [[
					layout(set = 0, binding = 0, r32f) uniform writeonly image2D out_dist;
					layout(set = 0, binding = 1) uniform sampler2D in_seed;
					void main() {
						ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
						ivec2 size = imageSize(out_dist);
						if (pos.x >= size.x || pos.y >= size.y) return;
						vec2 seed = texelFetch(in_seed, pos, 0).rg;
						float dist = (seed.x < 0.0) ? compute.max_dist : length(seed - vec2(pos));
						imageStore(out_dist, pos, vec4(dist, 0.0, 0.0, 1.0));
					}
				]],
		},
		combine = EasyPipeline.Compute{
			DescriptorSetCount = JFA_DESCRIPTOR_SET_COUNT,
			LocalSize = {x = 8, y = 8, z = 1},
			descriptor_sets = {
				{
					type = "storage_image",
					binding_index = 0,
					stageFlags = "compute",
					set_index = 0,
				},
				{
					type = "combined_image_sampler",
					binding_index = 1,
					stageFlags = "compute",
					set_index = 0,
				},
				{
					type = "combined_image_sampler",
					binding_index = 2,
					stageFlags = "compute",
					set_index = 0,
				},
				{
					type = "combined_image_sampler",
					binding_index = 3,
					stageFlags = "compute",
					set_index = 0,
				},
			},
			block = {
				{"max_dist", "float"},
			},
			write = function(self, block)
				block.max_dist = self.current_jfa_max_dist
				return block
			end,
			shader = [[
					layout(set = 0, binding = 0, rgba8) uniform writeonly image2D out_tex;
					layout(set = 0, binding = 1) uniform sampler2D dist_on_tex;
					layout(set = 0, binding = 2) uniform sampler2D dist_off_tex;
					layout(set = 0, binding = 3) uniform sampler2D mask_tex;

					float sample_bilinear_r(sampler2D tex, vec2 uv) {
						ivec2 size = textureSize(tex, 0);
						vec2 sample_pos = uv * vec2(size) - vec2(0.5);
						ivec2 p0 = ivec2(floor(sample_pos));
						vec2 frac = sample_pos - vec2(p0);
						ivec2 p1 = p0 + ivec2(1, 1);
						p0 = clamp(p0, ivec2(0), size - ivec2(1));
						p1 = clamp(p1, ivec2(0), size - ivec2(1));

						float v00 = texelFetch(tex, ivec2(p0.x, p0.y), 0).r;
						float v10 = texelFetch(tex, ivec2(p1.x, p0.y), 0).r;
						float v01 = texelFetch(tex, ivec2(p0.x, p1.y), 0).r;
						float v11 = texelFetch(tex, ivec2(p1.x, p1.y), 0).r;
						float vx0 = mix(v00, v10, frac.x);
						float vx1 = mix(v01, v11, frac.x);
						return mix(vx0, vx1, frac.y);
					}

					void main() {
						ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
						ivec2 size = imageSize(out_tex);
						if (pos.x >= size.x || pos.y >= size.y) return;
						vec2 uv = (vec2(pos) + vec2(0.5)) / vec2(size);
						float d_on = sample_bilinear_r(dist_on_tex, uv);
						float d_off = sample_bilinear_r(dist_off_tex, uv);
						vec4 mask_sample = texture(mask_tex, uv);
						float coverage = max(mask_sample.r, mask_sample.a);
						float dist = d_off - d_on;
						float aa_offset = coverage - 0.5;
						float edge_weight = 1.0 - smoothstep(0.0, 2.0, abs(dist));
						float shaded_dist = mix(dist, -aa_offset, edge_weight);
						float norm_dist = clamp(shaded_dist / (compute.max_dist * 2.0) + 0.5, 0.0, 1.0);
						imageStore(out_tex, pos, vec4(norm_dist, norm_dist, norm_dist, 1.0));
					}
				]],
		},
	}
	shared_jfa_pipelines[atlas_format] = self.jfa_pipelines
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
end

function META:GetAscent()
	local a, d = get_ascent_descent(self)
	return a
end

function META:GetDescent()
	local a, d = get_ascent_descent(self)
	return d
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
	-- Clear all cached glyphs
	local codes_to_reload = {}

	for code in pairs(self.chars) do
		table.insert(codes_to_reload, code)
		self.chars[code] = nil
	end

	-- Reload all glyphs
	for _, code in ipairs(codes_to_reload) do
		self:LoadGlyph(code)
	end

	-- Rebuild the atlas
	self:Rebuild()
	render.PopCommandBuffer()

	if own_cmd then
		cmd:End()
		render.SubmitAndWait(cmd)
	end
end

local scratch_size = {w = 0, h = 0}
local fb_pool = {}
local tex_pool = {}

local function get_temp_fb(self, w, h, format, mip_maps, filter)
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
			name = string.format("render2d sdf font scratch %s %dx%d", tostring(self:GetName() or "unnamed"), w, h),
			clear_color = {0, 0, 0, 0},
			format = format,
			mip_map_levels = mip_maps and "auto" or 1,
			min_filter = filter or "linear",
			mag_filter = filter or "linear",
			wrap_s = "clamp_to_edge",
			wrap_t = "clamp_to_edge",
		}
		fb._pool_key = key
		fb._temp_kind = "fb"
	end

	return fb
end

local function get_temp_tex(self, w, h, format, filter)
	local key = w .. "_" .. h .. "_" .. format .. "_" .. (filter or "linear")
	local pool = tex_pool[key]

	if not pool then
		pool = {}
		tex_pool[key] = pool
	end

	local tex = table.remove(pool)

	if not tex then
		tex = Texture.New{
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
		tex._pool_key = key
		tex._temp_kind = "tex"
	end

	return tex
end

local function release_temp_resource(resource)
	local key = resource._pool_key

	if resource._temp_kind == "tex" then
		local pool = tex_pool[key]

		if not pool then
			pool = {}
			tex_pool[key] = pool
		end

		table.insert(pool, resource)
		return
	end

	local pool = fb_pool[key]

	if not pool then
		pool = {}
		fb_pool[key] = pool
	end

	table.insert(pool, resource)
end

local function glyph_has_drawable_outline(glyph)
	local glyph_data = glyph and glyph.glyph_data

	if not glyph_data then return false end

	if not glyph_data.points or #glyph_data.points == 0 then return false end

	if not glyph_data.end_pts_of_contours or #glyph_data.end_pts_of_contours == 0 then
		return false
	end

	return true
end

local function get_metric_char(self, code)
	local data = self.chars[code]

	if data ~= nil then return data end

	self.metric_chars = self.metric_chars or {}
	data = self.metric_chars[code]

	if data ~= nil then return data end

	for i = 1, #self.Fonts do
		local font = self.Fonts[i]
		font:SetSize(self.Size)
		data = font:GetGlyph(code)

		if data then break end
	end

	if data == nil then data = false end

	self.metric_chars[code] = data
	return data
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

	local glyph

	for i = 1, #self.Fonts do
		local font = self.Fonts[i]
		font:SetSize(self.Size)
		glyph = font:GetGlyph(code)

		if glyph then break end
	end

	if not glyph or not glyph.glyph_data or glyph.w <= 0 or glyph.h <= 0 then
		return 0
	end

	if not glyph_has_drawable_outline(glyph) then return 0 end

	local spread = self:GetEffectiveSpread()
	local scale = SUPER_SAMPLING_SCALE
	local sw = (glyph.w + spread * 2) * scale
	local sh = (glyph.h + spread * 2) * scale
	local _, steps = get_next_pow2_and_steps(math.max(sw, sh))
	return (steps + 4) * 2 + 1
end

function META:GenerateSDF(mask_tex, sw, sh, target_w, target_h, temp_fbs)
	local p = self:GetJFAPipelines()
	local max_dim = math.max(sw, sh)
	local spread = self:GetEffectiveSpread()
	local cmd = assert(render.GetCommandBuffer(), "GenerateSDF requires an active command buffer")
	local p2 = get_next_pow2_and_steps(max_dim)
	-- Verify mask texture before JFA (need at least 20 valid pixels)
	debug_assert_sdf_texture(mask_tex, "mask_input", 5, 20, "mask texture (must have glyph pixels, not empty)")
	local tex_a = get_temp_tex(self, sw, sh, "r32g32_sfloat", "nearest")
	local tex_b = get_temp_tex(self, sw, sh, "r32g32_sfloat", "nearest")
	local tex_dist_on = get_temp_tex(self, sw, sh, "r32_sfloat", "nearest")
	local tex_dist_off = get_temp_tex(self, sw, sh, "r32_sfloat", "nearest")
	table.insert(temp_fbs, tex_a)
	table.insert(temp_fbs, tex_b)
	table.insert(temp_fbs, tex_dist_on)
	table.insert(temp_fbs, tex_dist_off)
	-- Keep the encoded distance range aligned with the actual glyph padding while
	-- still leaving a small minimum margin for blur and outline effects.
	local max_dist = math.max(4, spread) * SUPER_SAMPLING_SCALE
	p.final.current_jfa_max_dist = max_dist
	p.combine.current_jfa_max_dist = max_dist

	local function get_sampler(texture)
		return texture.sampler or render.CreateSampler(texture:GetSamplerConfig())
	end

	local function transition_image(texture, src_stage, dst_stage, src_access, dst_access, new_layout)
		local image = texture:GetImage()
		local old_layout = image.layout or "undefined"

		if old_layout == new_layout then return end

		cmd:PipelineBarrier{
			srcStage = src_stage,
			dstStage = dst_stage,
			imageBarriers = {
				{
					image = image,
					srcAccessMask = src_access,
					dstAccessMask = dst_access,
					oldLayout = old_layout,
					newLayout = new_layout,
				},
			},
		}
	end

	local function transition_to_storage(texture)
		local old_layout = texture:GetImage().layout or "undefined"
		local src_stage = "top_of_pipe"
		local src_access = "none"

		if old_layout == "shader_read_only_optimal" then
			src_stage = "compute"
			src_access = "shader_read"
		elseif old_layout == "general" then
			src_stage = "compute"
			src_access = "shader_read"
		end

		transition_image(texture, src_stage, "compute", src_access, "shader_write", "general")
	end

	local function transition_to_sampled(texture, dst_stage)
		transition_image(
			texture,
			"compute",
			dst_stage or "compute",
			"shader_write",
			"shader_read",
			"shader_read_only_optimal"
		)
	end

	local descriptor_limit = math.min(
		p.init.pipeline:GetDescriptorSetCount(),
		p.step.pipeline:GetDescriptorSetCount(),
		p.final.pipeline:GetDescriptorSetCount(),
		p.combine.pipeline:GetDescriptorSetCount()
	)

	if self._jfa_descriptor_slot_cmd ~= cmd then
		self._jfa_descriptor_slot_cmd = cmd
		self._jfa_descriptor_slot = 0
	end

	local function next_descriptor_slot()
		self._jfa_descriptor_slot = (self._jfa_descriptor_slot or 0) + 1

		if self._jfa_descriptor_slot > descriptor_limit then
			error(
				string.format(
					"sdf compute descriptor set ring exhausted in one command buffer (%d > %d)",
					self._jfa_descriptor_slot,
					descriptor_limit
				),
				2
			)
		end

		return self._jfa_descriptor_slot
	end

	local function run_jfa(mode, out_tex)
		local mode_name = mode == 0 and "on" or "off"
		p.init.current_jfa_mode = mode
		local slot = next_descriptor_slot()
		transition_to_storage(tex_a)
		p.init:UpdateDescriptorSet("storage_image", slot, 0, 0, tex_a:GetView())
		p.init:UpdateDescriptorSet("combined_image_sampler", slot, 1, 0, mask_tex:GetView(), get_sampler(mask_tex))
		p.init:DispatchForSize(nil, sw, sh, 1, slot)
		transition_to_sampled(tex_a)
		local current_tex = tex_a
		local next_tex = tex_b
		local step = p2 / 2

		while step >= 1 do
			local step_size = step
			slot = next_descriptor_slot()
			p.step.current_jfa_step = step_size
			transition_to_storage(next_tex)
			p.step:UpdateDescriptorSet("storage_image", slot, 0, 0, next_tex:GetView())
			p.step:UpdateDescriptorSet(
				"combined_image_sampler",
				slot,
				1,
				0,
				current_tex:GetView(),
				get_sampler(current_tex)
			)
			p.step:DispatchForSize(nil, sw, sh, 1, slot)
			transition_to_sampled(next_tex)
			current_tex, next_tex = next_tex, current_tex
			step = math.floor(step / 2)
		end

		-- Extra passes at step 1 to fix precision artifacts and "wiggling" spines
		for i = 1, 2 do
			slot = next_descriptor_slot()
			p.step.current_jfa_step = 1
			transition_to_storage(next_tex)
			p.step:UpdateDescriptorSet("storage_image", slot, 0, 0, next_tex:GetView())
			p.step:UpdateDescriptorSet(
				"combined_image_sampler",
				slot,
				1,
				0,
				current_tex:GetView(),
				get_sampler(current_tex)
			)
			p.step:DispatchForSize(nil, sw, sh, 1, slot)
			transition_to_sampled(next_tex)
			current_tex, next_tex = next_tex, current_tex
		end

		slot = next_descriptor_slot()
		transition_to_storage(out_tex)
		p.final:UpdateDescriptorSet("storage_image", slot, 0, 0, out_tex:GetView())
		p.final:UpdateDescriptorSet(
			"combined_image_sampler",
			slot,
			1,
			0,
			current_tex:GetView(),
			get_sampler(current_tex)
		)
		p.final:DispatchForSize(nil, sw, sh, 1, slot)
		transition_to_sampled(out_tex, "fragment")
	end

	run_jfa(0, tex_dist_on) -- Distance to ON pixels
	debug_assert_sdf_texture(tex_dist_on, "dist_on", 0, 20, "distance to ON pixels (after init+JFA)")
	run_jfa(1, tex_dist_off) -- Distance to OFF pixels
	debug_assert_sdf_texture(tex_dist_off, "dist_off", 0, 20, "distance to OFF pixels (after init+JFA)")
	local tex_final = get_temp_tex(self, target_w, target_h, self:GetAtlasFormat(), "linear")
	table.insert(temp_fbs, tex_final)
	local final_frame_index = next_descriptor_slot()
	transition_to_storage(tex_final)
	p.combine:UpdateDescriptorSet("storage_image", final_frame_index, 0, 0, tex_final:GetView())
	p.combine:UpdateDescriptorSet(
		"combined_image_sampler",
		final_frame_index,
		1,
		0,
		tex_dist_on:GetView(),
		get_sampler(tex_dist_on)
	)
	p.combine:UpdateDescriptorSet(
		"combined_image_sampler",
		final_frame_index,
		2,
		0,
		tex_dist_off:GetView(),
		get_sampler(tex_dist_off)
	)
	p.combine:UpdateDescriptorSet(
		"combined_image_sampler",
		final_frame_index,
		3,
		0,
		mask_tex:GetView(),
		get_sampler(mask_tex)
	)
	p.combine.current_jfa_max_dist = max_dist
	p.combine:DispatchForSize(nil, target_w, target_h, 1, final_frame_index)
	transition_to_sampled(tex_final)
	-- need to also wait for some reason
	cmd:End()
	render.SubmitAndWait(cmd)
	cmd:Begin()
	-- Check that SDF has meaningful variation (not all same value)
	debug_assert_sdf_texture(
		tex_final,
		"final_sdf",
		10,
		20,
		"final SDF output (must have variation, not uniform)"
	)
	return tex_final
end

function META:LoadGlyph(code, temp_fbs)
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
		local spread = self:GetEffectiveSpread()
		local sw = (glyph.w + spread * 2) * scale
		local sh = (glyph.h + spread * 2) * scale
		local used_temp_fbs = {}
		local format = self:GetAtlasFormat()
		local fb_ss = get_temp_fb(self, sw, sh, format, true)
		table.insert(used_temp_fbs, fb_ss)
		local own_cmd = false
		local cmd = render.GetCommandBuffer()

		if not cmd then
			cmd = render.GetCommandPool():AllocateCommandBuffer()
			cmd:Begin()
			own_cmd = true
		end

		do
			-- Debug: check glyph data
			if DEBUG then
				local gd = glyph.glyph_data
				local poly = gd and gd.poly
				local verts = gd and gd.points
				local contours = gd and gd.end_pts_of_contours
				print(
					string.format(
						"SDF debug glyph %d: has_poly=%d points=%d contours=%d glyph.w=%d h=%d bitmap_left=%d bitmap_top=%d",
						code,
						poly and 1 or 0,
						#((verts) or {}),
						#((contours) or {}),
						glyph.w,
						glyph.h,
						glyph.bitmap_left,
						glyph.bitmap_top
					)
				)
			end

			render2d.ResetState()
			local old_w, old_h = render2d.GetSize()
			render.PushCommandBuffer(cmd)
			fb_ss:Begin()
			local old_color = {render2d.GetColor()}
			render2d.SetColor(1, 1, 1, 1)
			local old_blend_mode = render2d.GetBlendMode()
			render2d.SetBlendPreset("alpha")
			render2d.PushSwizzleMode(render2d.GetSwizzleMode())
			scratch_size.w = sw
			scratch_size.h = sh
			render2d.UpdateScreenSize(scratch_size.w, scratch_size.h)
			render2d.BindPipeline()
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
			fb_ss:End()
			render.PopCommandBuffer()
			scratch_size.w = old_w
			scratch_size.h = old_h
			render2d.UpdateScreenSize(scratch_size.w, scratch_size.h)
		end

		if glyph_has_drawable_outline(glyph) then
			glyph.texture = self:GenerateSDF(
				fb_ss.color_texture,
				sw,
				sh,
				glyph.w + spread * 2,
				glyph.h + spread * 2,
				used_temp_fbs
			)
		else
			local fb_final = get_temp_fb(self, glyph.w + spread * 2, glyph.h + spread * 2, format, false)
			table.insert(used_temp_fbs, fb_final)
			render.PushCommandBuffer(cmd)
			fb_final:Begin()
			fb_final:End()
			render.PopCommandBuffer()
			glyph.texture = fb_final.color_texture
		end

		if own_cmd then
			local atlas_data = {
				w = glyph.w + spread * 2,
				h = glyph.h + spread * 2,
				texture = glyph.texture,
				flip_y = glyph.flip_y,
			}
			self.texture_atlas:Insert(code, atlas_data)
			glyph.atlas_data = atlas_data
			self.chars[code] = glyph
			self:Rebuild()
			cmd:End()
			render.SubmitAndWait(cmd)

			for _, fb in ipairs(used_temp_fbs) do
				release_temp_resource(fb)
			end

			self.rebuild = false
			return
		elseif temp_fbs then
			for _, fb in ipairs(used_temp_fbs) do
				table.insert(temp_fbs, fb)
			end
		end
	end

	local atlas_data = {
		w = glyph.w + self:GetEffectiveSpread() * 2,
		h = glyph.h + self:GetEffectiveSpread() * 2,
		texture = glyph.texture,
		flip_y = glyph.flip_y,
	}
	self.texture_atlas:Insert(code, atlas_data)
	glyph.atlas_data = atlas_data
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
		release_temp_resource(fb)
	end
end

local function get_draw_pass_cache(self, atlas)
	local cache = self.draw_pass_cache

	if not cache then
		cache = setmetatable({}, {__mode = "k"})
		self.draw_pass_cache = cache
	end

	local atlas_cache = cache[atlas]

	if atlas_cache then return atlas_cache end

	atlas_cache = {}
	cache[atlas] = atlas_cache
	return atlas_cache
end

local function get_draw_pass_cache_key(str, spacing, extra_space_advance)
	return tostring(spacing) .. "\0" .. tostring(extra_space_advance or 0) .. "\0" .. str
end

local function build_draw_pass_layout(self, str, spacing, atlas, extra_space_advance)
	local X, Y = 0, 0
	local i = 1
	local len = #str
	local str_byte = string.byte
	local utf8_uint32 = utf8.uint32
	local utf8_byte_length = utf8.byte_length
	local chars = self.chars
	local spread = self:GetEffectiveSpread()
	local scale_x = self.Scale.x
	local scale_y = self.Scale.y
	local size = self.Size
	local monospace = self.Monospace
	local tab_mult = self.TabWidthMultiplier
	local line_height = self:GetLineHeight()
	local space_glyph = chars[32] or self:GetChar(32)
	local tab_advance
	local entries = {}
	extra_space_advance = extra_space_advance or 0

	if monospace then
		tab_advance = spacing * tab_mult
	elseif space_glyph then
		tab_advance = (space_glyph.x_advance + spacing) * tab_mult
	else
		tab_advance = size * tab_mult
	end

	while i <= len do
		local byte = str_byte(str, i)
		local char_code
		local char_size

		if byte < 128 then
			char_code = byte
			char_size = 1
		else
			char_code = utf8_uint32(str, i)
			char_size = utf8_byte_length(str, i)
		end

		if char_code == 10 then
			X = 0
			Y = Y + line_height + spacing
		elseif char_code == 32 then
			X = X + size / 2 + extra_space_advance
		elseif char_code == 9 then
			X = X + tab_advance
		else
			local data = chars[char_code]

			if data then
				local atlas_data = data.atlas_data

				if atlas_data and atlas_data.page then
					entries[#entries + 1] = {
						texture = atlas_data.page.texture,
						uv = atlas_data.page_uv_normalized,
						x = (X + data.bitmap_left - spread) * scale_x,
						y = (Y + data.bitmap_top - spread) * scale_y,
						w = atlas_data.w * scale_x,
						h = atlas_data.h * scale_y,
						debug_x = (X - spread) * scale_x,
						debug_y = (Y - spread) * scale_y,
						debug_w = (data.x_advance + spread * 2) * scale_x,
					}
				end

				if monospace then
					X = X + spacing
				else
					X = X + data.x_advance + spacing
				end
			end
		end

		i = i + char_size
	end

	return {
		entries = entries,
		margin = spread * scale_x,
		debug_h = line_height * scale_y,
	}
end

local function get_draw_pass_layout(self, str, spacing, atlas, extra_space_advance)
	local atlas_cache = get_draw_pass_cache(self, atlas)
	local key = get_draw_pass_cache_key(str, spacing, extra_space_advance)
	local cached = atlas_cache[key]

	if cached then return cached end

	cached = build_draw_pass_layout(self, str, spacing, atlas, extra_space_advance)
	atlas_cache[key] = cached
	return cached
end

function META:GetLineHeight()
	local a, d = get_ascent_descent(self)
	return (a + d)
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
			local data = chars[32] or get_metric_char(self, 32)

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
			local data = chars[char_code] or get_metric_char(self, char_code)

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

function META:DrawPassImmediate(str, x, y, spacing, atlas, extra_space_advance)
	local render2d_SetTexture = render2d.SetTexture
	local render2d_DrawRectUV2f = render2d.DrawRectUV2f
	local render2d_PushColor = render2d.PushColor
	local render2d_DrawRect = render2d.DrawRect
	local render2d_PopColor = render2d.PopColor
	local old_texture = render2d.GetTexture()
	local last_texture = old_texture
	local debug = self.debug
	local layout = get_draw_pass_layout(self, str, spacing, atlas, extra_space_advance)
	local entries = layout.entries

	for i = 1, #entries do
		local entry = entries[i]
		local texture = entry.texture

		if texture ~= last_texture then
			render2d_SetTexture(texture)
			last_texture = texture
		end

		local uv = entry.uv
		render2d_DrawRectUV2f(
			x + entry.x,
			y + entry.y,
			entry.w,
			entry.h,
			uv[1],
			uv[2],
			uv[3],
			uv[4],
			nil,
			nil,
			nil,
			layout.margin
		)

		if debug then
			render2d_SetTexture(nil)
			render2d_PushColor(1, 0, 0, 0.25)
			render2d_DrawRect(x + entry.debug_x, y + entry.debug_y, entry.debug_w, layout.debug_h)
			render2d_PopColor()
			render2d_SetTexture(texture)
			last_texture = texture
		end
	end

	if last_texture ~= old_texture then render2d_SetTexture(old_texture) end
end

function META:DrawString(str, x, y, spacing, extra_space_advance)
	if not self:IsReady() then return end

	str = tostring(str)
	batch_load_glyphs(self, str)
	spacing = spacing or self.Spacing
	extra_space_advance = extra_space_advance or 0
	render2d.PushUV()
	render2d.PushSDFMode(true)
	render2d.PushSDFTexelRange(self:GetEffectiveSpread())
	self:DrawPassImmediate(str, x, y, spacing, self.texture_atlas, extra_space_advance)
	render2d.PopSDFTexelRange()
	render2d.PopSDFMode()
	render2d.PopUV()
end

do
	-- Drawing functions
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

		self.text_size_cache = self.text_size_cache or {}
		local cached = self.text_size_cache[str]

		if cached then return cached[1], cached[2] end

		local w, h = self:GetTextSizeNotCached(str)
		self.text_size_cache[str] = {w, h}
		return w, h
	end

	function META:MeasureText(str)
		return self:GetTextSize(str)
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
end

return META:Register()
