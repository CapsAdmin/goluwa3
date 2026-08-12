--[[HOTRELOAD
	--os.execute("luajit glw test sdf_fonts")
]]
local ffi = require("ffi")
local render2d = import("goluwa/render2d/render2d.lua")
local msdf_edges = import("goluwa/render2d/msdf_edges.lua")
local render = import("goluwa/render/render.lua")
local Texture = import("goluwa/render/texture.lua")
local Buffer = import("goluwa/render/vulkan/internal/buffer.lua")
local objects = import("goluwa/objects/objects.lua")
local utf8 = import("goluwa/string/utf8.lua")
local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
local event = import("goluwa/event.lua")
local META = objects.CreateTemplate("sdf_font")
META.Base = import("goluwa/render2d/fonts/base.lua")
META:GetSet("TabWidthMultiplier", 4)
META:IsSet("MSDF", false)
local SUPER_SAMPLING_SCALE = 4

function META.New(font_path, msdf)
	local self = META:CreateObject()
	self:SetMSDF(msdf)
	self:Initialize(font_path)
	return self
end

function META:GetEffectiveSpread()
	return math.max(2, math.ceil(self.Size / SUPER_SAMPLING_SCALE)) * SUPER_SAMPLING_SCALE
end

do
	local shared_jfa_pipelines = nil
	local JFA_DESCRIPTOR_SET_COUNT = 1024

	local function get_jfa_pipelines()
		if shared_jfa_pipelines then return shared_jfa_pipelines end

		shared_jfa_pipelines = {
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
						float dist = length(seed - vec2(pos));
						imageStore(out_dist, pos, vec4(dist, 0.0, 0.0, 1.0));
					}
				]],
			},
			combine_sdf = EasyPipeline.Compute{
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
						float norm_dist = clamp(dist / compute.max_dist + 0.5, 0.0, 1.0);
						imageStore(out_tex, pos, vec4(norm_dist, norm_dist, norm_dist, 1.0));
					}
				]],
			},
			combine_msdf = EasyPipeline.Compute{
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
					{
						type = "storage_buffer",
						binding_index = 4,
						stageFlags = "compute",
						set_index = 0,
					},
				},
				block = {{"max_dist", "float"}, {"num_edges", "int"}},
				write = function(self, block)
					block.max_dist = self.current_jfa_max_dist
					block.num_edges = self.current_num_edges
					return block
				end,
				shader = [[
					layout(set = 0, binding = 0, rgba8) uniform writeonly image2D out_tex;
					layout(set = 0, binding = 1) uniform sampler2D dist_on_tex;
					layout(set = 0, binding = 2) uniform sampler2D dist_off_tex;
					layout(set = 0, binding = 3) uniform sampler2D mask_tex;

					// Edge data: 5 floats per edge (x0, y0, x1, y1, channel)
					// channel: bit flags - bit0=R(1), bit1=G(2), bit2=B(4)
					layout(set = 0, binding = 4, std430) coherent buffer EdgeBuffer {
						float edges[];
					} edge_buf;

					// Signed distance from point p to segment a->b
					// Returns distance (always positive); sign determined separately
					float sdSegment(vec2 p, vec2 a, vec2 b) {
						vec2 ea = a - p;
						vec2 ab = b - a;
						float h = clamp(dot(ea, -ab) / dot(ab, ab), 0.0, 1.0);
						return length(ea + ab * h);
					}

					void main() {
						ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
						ivec2 size = imageSize(out_tex);
						if (pos.x >= size.x || pos.y >= size.y) return;

						// Sign oracle from JFA distance fields
						float d_on = texelFetch(dist_on_tex, pos, 0).r;
						float d_off = texelFetch(dist_off_tex, pos, 0).r;
						float dist = d_off - d_on;
						float d_sign = sign(dist);
						float abs_dist = abs(dist);

						// Brute-force min-distance per channel
						float min_r = abs_dist;
						float min_g = abs_dist;
						float min_b = abs_dist;
						vec2 p = vec2(pos);

						for (int i = 0; i < compute.num_edges; i++) {
							int idx = i * 5;
							vec2 a = vec2(edge_buf.edges[idx], edge_buf.edges[idx + 1]);
							vec2 b = vec2(edge_buf.edges[idx + 2], edge_buf.edges[idx + 3]);
							float channel = edge_buf.edges[idx + 4];
							float d = sdSegment(p, a, b);

							// channel is bit flags: 1=R, 2=G, 4=B
							if (mod(channel, 2.0) > 0.5) { min_r = min(min_r, d); }
							if (mod(channel / 2.0, 2.0) > 0.5) { min_g = min(min_g, d); }
							if (mod(channel / 4.0, 2.0) > 0.5) { min_b = min(min_b, d); }
						}

					// Apply sign and normalize
					float r_ch = clamp(d_sign * min_r / compute.max_dist + 0.5, 0.0, 1.0);
					float g_ch = clamp(d_sign * min_g / compute.max_dist + 0.5, 0.0, 1.0);
					float b_ch = clamp(d_sign * min_b / compute.max_dist + 0.5, 0.0, 1.0);

					imageStore(out_tex, pos, vec4(r_ch, g_ch, b_ch, 1.0));
					}
				]],
			},
		}
		return shared_jfa_pipelines
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

	local function next_descriptor_slot(self, cmd)
		if not self._jfa_descriptor_slot or self._jfa_descriptor_slot_cmd ~= cmd then
			self._jfa_descriptor_slot_cmd = cmd
			self._jfa_descriptor_slot = 0
		end

		self._jfa_descriptor_slot = self._jfa_descriptor_slot + 1

		if self._jfa_descriptor_slot > JFA_DESCRIPTOR_SET_COUNT then
			error(
				string.format(
					"sdf compute descriptor set ring exhausted in one command buffer (%d > %d)",
					self._jfa_descriptor_slot,
					JFA_DESCRIPTOR_SET_COUNT
				),
				2
			)
		end

		return self._jfa_descriptor_slot
	end

	function META:RenderGlyph(glyph)
		local debug_collect = {}
		local tex, texel_range = render.ExecuteCommand(function(cmd)
			local spread = self:GetEffectiveSpread()
			local output_w = math.ceil(glyph.w + spread)
			local output_h = math.ceil(glyph.h + spread)
			local super_w = output_w * SUPER_SAMPLING_SCALE
			local super_h = output_h * SUPER_SAMPLING_SCALE
			local saved_batch = render2d.SaveBatchState()
			render2d.state.runtime.batch.state:ClearPending()
			local mask_fb = self:GetTempFramebuffer(super_w, super_h, self:GetAtlasFormat(), true)
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
			local p = get_jfa_pipelines()
			local tex_a = self:GetTempTexture(super_w, super_h, "r32g32_sfloat", "nearest")
			local tex_b = self:GetTempTexture(super_w, super_h, "r32g32_sfloat", "nearest")
			local jfa_max_dist = spread * SUPER_SAMPLING_SCALE
			--
			local tex_dist_on = self:GetTempTexture(super_w, super_h, "r32_sfloat", "nearest")
			local tex_dist_off = self:GetTempTexture(super_w, super_h, "r32_sfloat", "nearest")
			p.final.current_jfa_max_dist = jfa_max_dist

			for mode = 0, 1 do
				p.init.current_jfa_mode = mode
				local slot = next_descriptor_slot(self, cmd)
				p.init:BindStorageImage(cmd, slot, 0, tex_a)
				p.init:BindSampledImage(cmd, slot, 1, mask_fb.color_texture)
				p.init:DispatchForSize(cmd, super_w, super_h, 1, slot)
				render.TransitionResourceToShaderRead(tex_a, {cmd = cmd, srcStage = "compute", srcAccess = "shader_write"})
				local current_tex = tex_a
				local next_tex = tex_b
				local p2 = get_next_pow2_and_steps(math.max(super_w, super_h))
				local step = p2 / 2

				while step >= 1 do
					local slot = next_descriptor_slot(self, cmd)
					p.step.current_jfa_step = step
					p.step:BindStorageImage(cmd, slot, 0, next_tex)
					p.step:BindSampledImage(cmd, slot, 1, current_tex)
					p.step:DispatchForSize(cmd, super_w, super_h, 1, slot)
					render.TransitionResourceToShaderRead(next_tex, {cmd = cmd, srcStage = "compute", srcAccess = "shader_write"})
					current_tex, next_tex = next_tex, current_tex
					step = math.floor(step / 2)
				end

				for i = 1, 2 do
					local slot = next_descriptor_slot(self, cmd)
					p.step.current_jfa_step = 1
					p.step:BindStorageImage(cmd, slot, 0, next_tex)
					p.step:BindSampledImage(cmd, slot, 1, current_tex)
					p.step:DispatchForSize(cmd, super_w, super_h, 1, slot)
					render.TransitionResourceToShaderRead(next_tex, {cmd = cmd, srcStage = "compute", srcAccess = "shader_write"})
					current_tex, next_tex = next_tex, current_tex
				end

				local out_tex = mode == 0 and tex_dist_on or tex_dist_off
				local slot = next_descriptor_slot(self, cmd)
				p.final:BindStorageImage(cmd, slot, 0, out_tex)
				p.final:BindSampledImage(cmd, slot, 1, current_tex)
				p.final:DispatchForSize(cmd, super_w, super_h, 1, slot)

				if debug_collect then
					debug_collect[mode == 0 and "dist_on" or "dist_off"] = out_tex
					debug_collect[(mode == 0 and "dist_on" or "dist_off") .. "_a"] = tex_a
					debug_collect[(mode == 0 and "dist_on" or "dist_off") .. "_b"] = tex_b
				end

				render.TransitionResourceToShaderRead(out_tex, {cmd = cmd, srcStage = "compute", srcAccess = "shader_write"})
			end

			local tex_final = self:GetTempTexture(output_w, output_h, self:GetAtlasFormat(), "linear")
			local slot = next_descriptor_slot(self, cmd)
			local pipe_combine = self.MSDF and p.combine_msdf or p.combine_sdf
			pipe_combine.current_jfa_max_dist = jfa_max_dist
			local tex_combine = self:GetTempTexture(super_w, super_h, self:GetAtlasFormat(), "linear")
			pipe_combine:BindStorageImage(cmd, slot, 0, tex_combine)
			pipe_combine:BindSampledImage(cmd, slot, 1, tex_dist_on)
			pipe_combine:BindSampledImage(cmd, slot, 2, tex_dist_off)
			pipe_combine:BindSampledImage(cmd, slot, 3, mask_fb.color_texture)

			if self.MSDF then
				local edges = msdf_edges.ExtractEdges(
					glyph,
					{
						scale = self.Size / glyph.units_per_em,
						super_scale = SUPER_SAMPLING_SCALE,
						pad = spread * SUPER_SAMPLING_SCALE / 2,
						curve_steps = 8,
						bearing_y = glyph.bearing_y,
						y_max = glyph.y_max,
					}
				)
				local num_edges = #edges
				pipe_combine.current_num_edges = num_edges
				-- Build edge buffer: 5 floats per edge (x0, y0, x1, y1, channel)
				local edge_data = ffi.new("float[?]", num_edges * 5)

				for i, edge in ipairs(edges) do
					local idx = (i - 1) * 5
					edge_data[idx] = edge[1]
					edge_data[idx + 1] = edge[2]
					edge_data[idx + 2] = edge[3]
					edge_data[idx + 3] = edge[4]
					edge_data[idx + 4] = edge[5]
				end

				local edge_buffer = Buffer.New{
					device = render.GetDevice(),
					size = num_edges * 5 * 4,
					usage = {"storage_buffer"},
				}
				edge_buffer:CopyData(edge_data, num_edges * 5 * 4)
				pipe_combine:UpdateDescriptorSet(
					"storage_buffer",
					slot,
					4,
					0,
					edge_buffer,
					num_edges * 5 * 4
				)
			end

			pipe_combine:DispatchForSize(cmd, super_w, super_h, 1, slot)
			render.TransitionResourceToTransferSrc(tex_combine, {cmd = cmd, srcStage = "compute", srcAccess = "shader_write"})
			render.TransitionResourceToTransferDst(tex_final, {cmd = cmd, srcStage = "compute", srcAccess = "shader_write"})
			cmd:BlitImage{
				src_image = tex_combine.image,
				dst_image = tex_final.image,
				src_layout = "transfer_src_optimal",
				dst_layout = "transfer_dst_optimal",
				src_width = super_w,
				src_height = super_h,
				dst_width = output_w,
				dst_height = output_h,
				filter = "linear",
			}
			render.TransitionResourceToShaderRead(tex_final, {cmd = cmd, srcStage = "transfer", srcAccess = "transfer_write"})

			if debug_collect then
				debug_collect.final = tex_final
				debug_collect.combine = tex_combine
				debug_collect.mask = mask_fb.color_texture
			end

			return tex_final, spread
		end)

		if debug_collect then self:OnTextureGenerated(glyph, debug_collect) end

		glyph.texture = tex
		glyph.atlas_data = {
			w = tex:GetSize().x,
			h = tex:GetSize().y,
			texture = tex,
			texel_range = texel_range,
		}
	end
end

local DEBUG = false

function META:OnTextureGenerated(glyph, textures)
	if not DEBUG then return end

	if not self.MSDF then return end

	local str = string.char(glyph.char_code)

	if str == "T" then
		for name, tex in pairs(textures) do
			tex:Download():SaveAs("tmp/sdf_glyphs/" .. str .. "_" .. name .. ".png")
		end
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
