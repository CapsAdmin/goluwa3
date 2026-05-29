local render = import("goluwa/render/render.lua")
local system = import("goluwa/system.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local compute_helpers = import("goluwa/render3d/compute_helpers.lua")
local COMPUTE_LOCAL_SIZE = {x = 8, y = 8, z = 1}

local function get_scene_source_texture()
	return post_source.GetSceneSourceTexture({name = "blit_compute"})
end

local function get_bloom_texture()
	if not render3d.pipelines.bloom_up0 then return nil end

	local framebuffer = render3d.pipelines.bloom_up0:GetFramebuffer()

	if not framebuffer then return nil end

	return framebuffer:GetAttachment(1)
end

local function get_luminance_texture()
	if not render3d.pipelines.luminance or not render3d.pipelines.luminance.framebuffers then
		return nil
	end

	local current_idx = system.GetFrameNumber() % 2 + 1
	local framebuffer = render3d.pipelines.luminance:GetFramebuffer(current_idx)

	if not framebuffer then return nil end

	return framebuffer:GetAttachment(1)
end

local compute_shader = [[
	layout(set = 0, binding = 0, rgba16f) uniform writeonly image2D out_color;
	layout(set = 0, binding = 1) uniform sampler2D source_tex;
	layout(set = 0, binding = 2) uniform sampler2D bloom_tex;
	layout(set = 0, binding = 3) uniform sampler2D luma_tex;
	]] .. compute_helpers.GetScreenHelpersGLSL() .. compute_helpers.GetColorHelpersGLSL() .. [[

	void main() {
		ivec2 pos = get_screen_pos();
		ivec2 size = imageSize(out_color);

		if (!is_screen_pos_in_bounds(pos, size)) return;

		if (compute.has_source_tex == 0) {
			imageStore(out_color, pos, vec4(1.0, 0.0, 1.0, 1.0));
			return;
		}

		vec2 uv = get_screen_uv(pos, size);
		vec3 col = texture(source_tex, uv).rgb;

		if (compute.is_debug_view == 1) {
			col = clamp(col, vec3(0.0), vec3(1.0));

			if (compute.requires_manual_gamma == 1) {
				col = LinearToSRGB(col);
			}

			imageStore(out_color, pos, vec4(col, 1.0));
			return;
		}

		vec3 bloom = vec3(0.0);

		if (compute.has_bloom_tex != 0) {
			bloom = texture(bloom_tex, uv).rgb;
		}

		float exposure = 1.0;

		if (compute.has_luma_tex != 0) {
			float avg_log_luma = 0.0;
			int samples = 0;

			for (float y = 0.125; y < 1.0; y += 0.25) {
				for (float x = 0.125; x < 1.0; x += 0.25) {
					avg_log_luma += texture(luma_tex, vec2(x, y)).r;
					samples++;
				}
			}

			avg_log_luma /= float(samples);
			float avg_luma = exp2(avg_log_luma);
			float target_luma = 0.5;
			exposure = target_luma / max(avg_luma, 0.001);
			exposure = clamp(exposure, 0.1, 4.0);
		}

		float bloom_luma = dot(bloom, vec3(0.2126, 0.7152, 0.0722));
		float bloom_strength = 0.03;
		float bloom_exposure_scale = clamp(1.0 / sqrt(max(exposure, 0.35)), 0.7, 1.25);
		float bloom_soft_clip = 1.0 / (1.0 + bloom_luma * 0.35);
		col += bloom * bloom_strength * bloom_exposure_scale * bloom_soft_clip;

		if (compute.is_hdr == 1) {
			col = tonemap(pow(col * 1.5, vec3(0.8)), exposure) * 1.2;
		} else {
			col = tonemap_lottes(col * exposure);
		}

		if (compute.requires_manual_gamma == 1) {
			col = LinearToSRGB(col);
		}

		vec2 vignette_uv = uv * 2.0 - 1.0;
		float aspect = float(textureSize(source_tex, 0).x) / float(textureSize(source_tex, 0).y);
		vignette_uv.x *= aspect;
		float vignette = smoothstep(4.0, 0.6, length(vignette_uv));
		col *= vignette;

		imageStore(out_color, pos, vec4(col, 1.0));
	}
]]
local r = {
	{
		name = "blit_compute",
		ComputePass = true,
		ColorFormat = {{"r16g16b16a16_sfloat", {"color", "rgba"}}},
		LocalSize = COMPUTE_LOCAL_SIZE,
		storage_images = {
			{
				binding_index = 0,
				attachment = 1,
				dst_stage = "fragment",
			},
		},
		sampled_images = {
			{
				binding_index = 1,
				get_texture = get_scene_source_texture,
			},
			{
				binding_index = 2,
				get_texture = get_bloom_texture,
			},
			{
				binding_index = 3,
				get_texture = get_luminance_texture,
			},
		},
		block = {
			{"has_source_tex", "int"},
			{"is_debug_view", "int"},
			{"has_bloom_tex", "int"},
			{"has_luma_tex", "int"},
			{"requires_manual_gamma", "int"},
			{"is_hdr", "int"},
		},
		write = function(self, block)
			block.has_source_tex = get_scene_source_texture() and 1 or 0
			block.is_debug_view = 0
			block.has_bloom_tex = get_bloom_texture() and 1 or 0
			block.has_luma_tex = get_luminance_texture() and 1 or 0
			block.requires_manual_gamma = render.target:RequiresManualGamma() and 1 or 0
			block.is_hdr = render.target:IsHDR() and 1 or 0
			return block
		end,
		shader = compute_shader,
	},
	{
		name = "blit",
		RasterizationSamples = function()
			return render.target.samples
		end,
		on_pre_draw = function(self)
			self._cached_blit_source_tex = -1

			if not render3d.pipelines.blit_compute then return end

			local framebuffer = render3d.pipelines.blit_compute:GetFramebuffer()

			if not framebuffer then return end

			local texture = framebuffer:GetAttachment(1)

			if not texture then return end

			self._cached_blit_source_tex = self:GetTextureIndex(texture)
		end,
		fragment = {
			push_constants = {
				{
					name = "blit_present",
					block = {
						{"source_tex", "int"},
					},
					write = function(self, block)
						block.source_tex = self._cached_blit_source_tex or -1
						return block
					end,
				},
			},
			shader = [[
				layout(location = 0) out vec4 frag_color;

				void main() {
					if (blit_present.source_tex == -1) {
						frag_color = vec4(1.0, 0.0, 1.0, 1.0);
						return;
					}

					frag_color = texture(TEXTURE(blit_present.source_tex), in_uv);
				}
			]],
		},
		CullMode = "none",
		DepthTest = false,
		DepthWrite = false,
	},
}

if HOTRELOAD then
	import("goluwa/timer.lua").Delay(0, function()
		render3d.Initialize()
	end)
end

return r
