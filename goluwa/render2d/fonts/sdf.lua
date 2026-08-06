--[[HOTRELOAD
	--os.execute("luajit glw test sdf_fonts")
]]
local render2d = import("goluwa/render2d/render2d.lua")
local render = import("goluwa/render/render.lua")
local Texture = import("goluwa/render/texture.lua")
local objects = import("goluwa/objects/objects.lua")
local utf8 = import("goluwa/string/utf8.lua")
local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
local AtlasFont = import("goluwa/render2d/fonts/atlas_font.lua")
local event = import("goluwa/event.lua")
-- Debug mode:
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

local META = objects.CreateTemplate("sdf_font")
META.Base = AtlasFont
META:GetSet("LoadSpeed", 10)
META:GetSet("TabWidthMultiplier", 4)
META:GetSet("Flags")

function META:__copy()
	return self
end

function META.New(font_path)
	local self = META:CreateObject()
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

	return self
end

function META:GetEffectiveSpread()
	return math.max(2, math.floor(self.Size))
end

local shared_jfa_pipelines = {}
local JFA_DESCRIPTOR_SET_COUNT = 1024

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
			block = {{"mode", "int"}},
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
						vec2 seed = (compute.mode == 0) ? (mask > 0.0 ? vec2(pos) : vec2(-1.0)) : (mask < 1 ? vec2(pos) : vec2(-1.0));
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
			block = {{"step_size", "int"}},
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
			block = {{"max_dist", "float"}},
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
			block = {{"max_dist", "float"}},
			write = function(self, block)
				block.max_dist = self.current_jfa_max_dist
				return block
			end,
			shader = [[
						layout(set = 0, binding = 0, rgba8) uniform writeonly image2D out_tex;
						layout(set = 0, binding = 1) uniform sampler2D dist_on_tex;
						layout(set = 0, binding = 2) uniform sampler2D dist_off_tex;
						layout(set = 0, binding = 3) uniform sampler2D mask_tex;

						void main() {
							ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
							ivec2 size = imageSize(out_tex);
							if (pos.x >= size.x || pos.y >= size.y) return;
							ivec2 dist_size = textureSize(dist_on_tex, 0);
							ivec2 sample_pos = clamp(pos, ivec2(0), dist_size - ivec2(1));
							float d_on = texelFetch(dist_on_tex, sample_pos, 0).r;
							float d_off = texelFetch(dist_off_tex, sample_pos, 0).r;
							float dist = d_off - d_on;
							float norm_dist = clamp(dist / (compute.max_dist * 2.0) + 0.5, 0.0, 1.0);
							imageStore(out_tex, pos, vec4(norm_dist, norm_dist, norm_dist, 1.0));
						}
					]],
		},
	}
	shared_jfa_pipelines[atlas_format] = self.jfa_pipelines
	return self.jfa_pipelines
end

local SUPER_SAMPLING_SCALE = 4
local COMBINE_SCALE = 4

local function get_metric_char(self, code)
	local data = self.chars[code]

	if data ~= nil then return data end

	self.metric_chars = self.metric_chars or {}
	data = self.metric_chars[code]

	if data ~= nil then return data end

	data = self:GetMetricGlyph(code)
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

local function get_temp_tex(self, w, h, format, filter)
	return self:GetTempTexture(w, h, format, filter)
end

function META:GenerateSDF(mask_tex, sw, sh, target_w, target_h, temp_fbs, cmd)
	local p = self:GetJFAPipelines()
	local max_dim = math.max(sw, sh)
	local spread = self:GetEffectiveSpread()
	-- Always use our own command buffer to avoid render pass conflicts and descriptor lifetime issues
	cmd = render.GetCommandPool():AllocateCommandBuffer()
	cmd:Begin()
	local p2 = get_next_pow2_and_steps(max_dim)
	debug_assert_sdf_texture(mask_tex, "mask_input", 5, 20, "mask texture (must have glyph pixels, not empty)")
	local tex_a = get_temp_tex(self, sw, sh, "r32g32_sfloat", "nearest")
	local tex_b = get_temp_tex(self, sw, sh, "r32g32_sfloat", "nearest")
	local tex_dist_on = get_temp_tex(self, sw, sh, "r32_sfloat", "nearest")
	local tex_dist_off = get_temp_tex(self, sw, sh, "r32_sfloat", "nearest")
	table.insert(temp_fbs, tex_a)
	table.insert(temp_fbs, tex_b)
	table.insert(temp_fbs, tex_dist_on)
	table.insert(temp_fbs, tex_dist_off)
	local glyph_superspace = math.max(sw, sh) - spread * 2 * SUPER_SAMPLING_SCALE
	local max_dist = math.max(4 * SUPER_SAMPLING_SCALE, glyph_superspace * 0.5)
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
		image.layout = new_layout
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
		p.init.current_jfa_mode = mode
		local slot = next_descriptor_slot()
		transition_to_storage(tex_a)
		p.init:UpdateDescriptorSet("storage_image", slot, 0, 0, tex_a:GetView())
		p.init:UpdateDescriptorSet("combined_image_sampler", slot, 1, 0, mask_tex:GetView(), get_sampler(mask_tex))
		p.init:DispatchForSize(cmd, sw, sh, 1, slot)
		transition_to_sampled(tex_a)
		local current_tex = tex_a
		local next_tex = tex_b
		local step = p2 / 2

		while step >= 1 do
			slot = next_descriptor_slot()
			p.step.current_jfa_step = step
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
			p.step:DispatchForSize(cmd, sw, sh, 1, slot)
			transition_to_sampled(next_tex)
			current_tex, next_tex = next_tex, current_tex
			step = math.floor(step / 2)
		end

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
			p.step:DispatchForSize(cmd, sw, sh, 1, slot)
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
		p.final:DispatchForSize(cmd, sw, sh, 1, slot)
		transition_to_sampled(out_tex, "fragment")
	end

	run_jfa(0, tex_dist_on)
	debug_assert_sdf_texture(tex_dist_on, "dist_on", 0, 20, "distance to ON pixels (after init+JFA)")
	run_jfa(1, tex_dist_off)
	debug_assert_sdf_texture(tex_dist_off, "dist_off", 0, 20, "distance to OFF pixels (after init+JFA)")
	local combine_w = target_w * COMBINE_SCALE
	local combine_h = target_h * COMBINE_SCALE
	local tex_combine = get_temp_tex(self, combine_w, combine_h, self:GetAtlasFormat(), "linear")
	table.insert(temp_fbs, tex_combine)
	local tex_final = get_temp_tex(self, target_w, target_h, self:GetAtlasFormat(), "linear")
	table.insert(temp_fbs, tex_final)
	local final_frame_index = next_descriptor_slot()
	transition_to_storage(tex_combine)
	p.combine:UpdateDescriptorSet("storage_image", final_frame_index, 0, 0, tex_combine:GetView())
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
	p.combine:DispatchForSize(cmd, combine_w, combine_h, 1, final_frame_index)
	transition_image(
		tex_combine,
		"compute",
		"transfer",
		"shader_read",
		"transfer_read",
		"transfer_src_optimal"
	)
	transition_image(
		tex_final,
		"compute",
		"transfer",
		"shader_write",
		"transfer_write",
		"transfer_dst_optimal"
	)
	cmd:BlitImage{
		src_image = tex_combine.image,
		dst_image = tex_final.image,
		src_layout = "transfer_src_optimal",
		dst_layout = "transfer_dst_optimal",
		src_width = combine_w,
		src_height = combine_h,
		dst_width = target_w,
		dst_height = target_h,
		filter = "linear",
	}
	transition_image(
		tex_final,
		"transfer",
		"fragment",
		"transfer_write",
		"shader_read",
		"shader_read_only_optimal"
	)
	cmd:End()
	render.SubmitAndWait(cmd)
	return tex_final
end

function META:GetAtlasPadding(w, h)
	local spread = self:GetEffectiveSpread()
	return (w + spread * 2) * SUPER_SAMPLING_SCALE,
	(h + spread * 2) * SUPER_SAMPLING_SCALE
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

function META:RenderGlyph(glyph, used_temp_fbs)
	local scale = SUPER_SAMPLING_SCALE
	local spread = self:GetEffectiveSpread()
	local sw = (glyph.w + spread * 2) * scale
	local sh = (glyph.h + spread * 2) * scale
	local format = self:GetAtlasFormat()
	local fb_ss = self:GetTempFramebuffer(sw, sh, format, true)
	table.insert(used_temp_fbs, fb_ss)
	-- Render glyph mask to framebuffer
	local cmd = render.GetCommandPool():AllocateCommandBuffer()
	cmd:Begin()

	do
		if DEBUG then
			local gd = glyph.glyph_data
			print(
				string.format(
					"SDF debug glyph %d: has_poly=%d points=%d contours=%d glyph.w=%d h=%d bitmap_left=%d bitmap_top=%d",
					code,
					gd and gd.poly and 1 or 0,
					#((gd and gd.points) or {}),
					#((gd and gd.end_pts_of_contours) or {}),
					glyph.w,
					glyph.h,
					glyph.bitmap_left,
					glyph.bitmap_top
				)
			)
		end

		local saved_batch = render2d.SaveBatchState()
		render2d.state.runtime.batch.state:ClearPending()
		fb_ss:Begin(cmd)
		render2d.PushBlendPreset("alpha")
		render.PushCommandBuffer(cmd)
		render2d.PushScreenSize(sw, sh)
		render2d.PushMatrix()
		render2d.LoadIdentity()
		render2d.Translate(spread * scale, (glyph.h + spread) * scale)
		render2d.Scale(scale, -scale)
		render2d.Translatef(-glyph.bitmap_left, -glyph.bitmap_top)
		self:DrawGlyph(glyph.glyph_data)
		render2d.FlushBatches("glyph_load")
		render2d.PopMatrix()
		render.PopCommandBuffer()
		render2d.PopScreenSize()
		render2d.PopBlendMode()
		render2d.RestoreBatchState(saved_batch)
		fb_ss:End(cmd)
	end

	-- Submit mask rendering before GenerateSDF reads it
	cmd:End()
	render.SubmitAndWait(cmd)
	-- Capture the texture reference before releasing the framebuffer
	local mask_tex = fb_ss.color_texture

	if glyph_has_drawable_outline(glyph) then
		glyph.texture = self:GenerateSDF(mask_tex, sw, sh, glyph.w + spread * 2, glyph.h + spread * 2, used_temp_fbs)
	else
		local fb_final = self:GetTempFramebuffer(glyph.w + spread * 2, glyph.h + spread * 2, format, false)
		table.insert(used_temp_fbs, fb_final)
		cmd = render.GetCommandPool():AllocateCommandBuffer()
		cmd:Begin()
		fb_final:Begin(cmd)
		fb_final:End(cmd)
		cmd:End()
		render.SubmitAndWait(cmd)
		glyph.texture = fb_final.color_texture
	end

	glyph.atlas_data = {
		w = glyph.w + spread * 2,
		h = glyph.h + spread * 2,
		texture = glyph.texture,
		flip_y = glyph.flip_y,
	}
end

local str_byte = string.byte
local utf8_uint32 = utf8.uint32
local utf8_byte_length = utf8.byte_length

local function build_draw_pass_layout(self, str, spacing, extra_space_advance)
	local X, Y = 0, 0
	local i = 1
	local spread = self:GetEffectiveSpread()
	local line_height = self:GetLineHeight()
	local space_glyph = self:GetChar(32)
	local entries = {}

	while i <= #str do
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
			X = X + self.Size / 2 + extra_space_advance
		elseif char_code == 9 then
			if self.Monospace then
				X = X + spacing * self.TabWidthMultiplier
			elseif space_glyph then
				X = X + (space_glyph.x_advance + spacing) * self.TabWidthMultiplier
			else
				X = X + self.Size * self.TabWidthMultiplier
			end
		else
			local data = self.chars[char_code]

			if data then
				local atlas_data = data.atlas_data

				if atlas_data and atlas_data.page then
					entries[#entries + 1] = {
						texture = atlas_data.page.texture,
						uv = atlas_data.page_uv_normalized,
						x = (X + data.bitmap_left - spread) * self.Scale.x,
						y = (Y + data.bitmap_top - spread) * self.Scale.y,
						w = atlas_data.w * self.Scale.x,
						h = atlas_data.h * self.Scale.y,
						debug_x = (X - spread) * self.Scale.x,
						debug_y = (Y - spread) * self.Scale.y,
						debug_w = (data.x_advance + spread * 2) * self.Scale.x,
					}
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

		i = i + char_size
	end

	return {
		entries = entries,
		margin = spread * self.Scale.x,
		debug_h = line_height * self.Scale.y,
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

function META:DrawPass(str, x, y, spacing, extra_space_advance)
	local old_texture = render2d.GetTexture()
	local last_texture = old_texture
	local layout = get_draw_pass_layout(self, str, spacing, extra_space_advance or 0)

	for i = 1, #layout.entries do
		local entry = layout.entries[i]
		local texture = entry.texture

		if texture ~= last_texture then
			render2d_SetTexture(texture)
			last_texture = texture
		end

		render2d_DrawRectUV2f(
			x + entry.x,
			y + entry.y,
			entry.w,
			entry.h,
			entry.uv[1],
			entry.uv[2],
			entry.uv[3],
			entry.uv[4],
			nil,
			nil,
			nil,
			layout.margin
		)

		if self.debug then
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
	self:LoadGlyphsFromString(str)
	spacing = spacing or self.Spacing
	extra_space_advance = extra_space_advance or 0
	render2d.PushUV()
	render2d.PushSDFMode(true)
	render2d.PushSDFTexelRange(self:GetEffectiveSpread() * 4)
	self:DrawPass(str, x, y, spacing, extra_space_advance)
	render2d.PopSDFTexelRange()
	render2d.PopSDFMode()
	render2d.PopUV()
end

return META:Register()
