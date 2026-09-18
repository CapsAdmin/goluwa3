local render = import("goluwa/render/render.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local compute_helpers = import("goluwa/render3d/compute_helpers.lua")
local system = import("goluwa/system.lua")
local COMPUTE_LOCAL_SIZE = {x = 8, y = 8, z = 1}

local function get_scene_source_texture()
	return post_source.GetSceneSourceTexture({name = "blit_compute"})
end

local exposure_target_luma = 0.2
local exposure_min = 0.00001
local exposure_max = 100.0
local exposure_bootstrap = 0.0001
local exposure_tau_light_adapt = 0.5
local exposure_tau_dark_adapt = 1.5
local log2 = math.log(2)
local exposure_log_target_luma = math.log(exposure_target_luma) / log2
local exposure_log_min = math.log(exposure_min) / log2
local exposure_log_max = math.log(exposure_max) / log2
local last_exposure_time

local function get_exposure_dt()
	local t = system.GetElapsedTime()
	local dt = last_exposure_time and (t - last_exposure_time) or 1 / 60
	last_exposure_time = t
	return math.clamp(dt, 0.0, 0.1)
end

local function get_exposure_feedback_attachment()
	return system.GetFrameNumber() % 2 == 0 and 1 or 2
end

local function get_exposure_feedback_texture()
	local pipeline = render3d.pipelines.exposure_feedback

	if not pipeline or not pipeline.framebuffers then return nil end

	return pipeline:GetFramebuffer():GetAttachment(get_exposure_feedback_attachment())
end

local exposure_feedback_shader = [[
	layout(set = 0, binding = 0, r32f) uniform writeonly image2D out_exposure;
	layout(set = 0, binding = 1) uniform sampler2D source_tex;
	layout(set = 0, binding = 2) uniform sampler2D prev_exposure_tex;

	void main() {
		if (compute.has_source_tex == 0) return;

		float prev = texture(prev_exposure_tex, vec2(0.5)).r;
		if (!(prev > 0.0)) prev = ]] .. string.format("%.7g", exposure_bootstrap) .. [[;
		prev = clamp(prev, ]] .. string.format("%.7g", exposure_min) .. [[, ]] .. string.format("%.7g", exposure_max) .. [[);

		float avg_log_luma = 0.0;
		int samples = 0;

		for (float y = 0.125; y < 1.0; y += 0.25) {
			for (float x = 0.125; x < 1.0; x += 0.25) {
				vec3 luma_col = texture(source_tex, vec2(x, y)).rgb;
				avg_log_luma += log2(max(dot(luma_col, vec3(0.2126, 0.7152, 0.0722)), 0.0001));
				samples++;
			}
		}

		avg_log_luma /= float(samples);

		float log_target = clamp(
			]] .. string.format("%.7g", exposure_log_target_luma) .. [[ - avg_log_luma,
			]] .. string.format("%.7g", exposure_log_min) .. [[,
			]] .. string.format("%.7g", exposure_log_max) .. [[
		);
		float log_prev = log2(prev);
		float tau = log_target > log_prev
			? ]] .. string.format("%.7g", exposure_tau_dark_adapt) .. [[
			: ]] .. string.format("%.7g", exposure_tau_light_adapt) .. [[;
		float k = 1.0 - exp(-compute.dt / tau);
		imageStore(out_exposure, ivec2(0, 0), vec4(exp2(log_prev + (log_target - log_prev) * k), 0.0, 0.0, 1.0));
	}
]]
local exposure_feedback_pass = {
	name = "exposure_feedback",
	ComputePass = true,
	ColorFormat = {
		{"r32_sfloat", {"exposure", "r"}},
		{"r32_sfloat", {"exposure_prev", "r"}},
	},
	FramebufferSize = {x = 1, y = 1},
	framebuffer_count = 1,
	LocalSize = {x = 1, y = 1, z = 1},
	storage_images = {
		{
			binding_index = 0,
			get_texture = function(self, fb)
				return fb:GetAttachment(get_exposure_feedback_attachment())
			end,
			dst_stage = "compute",
		},
	},
	sampled_images = {
		{
			binding_index = 1,
			get_texture = function()
				return post_source.GetSceneSourceTexture({name = "exposure_feedback"})
			end,
		},
		{
			binding_index = 2,
			get_texture = function(self, fb)
				return fb:GetAttachment(get_exposure_feedback_attachment() == 1 and 2 or 1)
			end,
		},
	},
	block = {
		{"has_source_tex", "int"},
		{"dt", "float"},
	},
	write = function(self, block)
		block.has_source_tex = post_source.GetSceneSourceTexture({name = "exposure_feedback"}) and 1 or 0
		block.dt = get_exposure_dt()
		return block
	end,
	shader = exposure_feedback_shader,
}

local function get_bloom_source_texture()
	if not render3d.pipelines.bloom_up2 then return nil end

	local framebuffer = render3d.pipelines.bloom_up2:GetFramebuffer()

	if not framebuffer then return nil end

	return framebuffer:GetAttachment(1)
end

local function get_bloom_merge_texture()
	return get_scene_source_texture()
end

local bloom_merge_strength = 0.65
local bloom_threshold = 1.1
local bloom_knee = 0.6
local bloom_veil_strength = 0.05
local bloom_veil_soft_clip = 0.5
local compute_shader = [[
	layout(set = 0, binding = 0, r11f_g11f_b10f) uniform writeonly image2D out_color;
	layout(set = 0, binding = 1) uniform sampler2D source_tex;
	layout(set = 0, binding = 2) uniform sampler2D bloom_source_tex;
	layout(set = 0, binding = 3) uniform sampler2D bloom_merge_tex;
	layout(set = 0, binding = 4) uniform sampler2D exposure_tex;
	]] .. compute_helpers.GetScreenHelpersGLSL() .. compute_helpers.GetColorHelpersGLSL() .. [[

	vec3 extract_bloom(vec3 bloom_input, float exposure) {
		float brightness = dot(bloom_input, vec3(0.2126, 0.7152, 0.0722)) * exposure;
		float soft = brightness - ]] .. string.format("%.7g", bloom_threshold) .. [[ + ]] .. string.format("%.7g", bloom_knee) .. [[;
		soft = clamp(soft, 0.0, 2.0 * ]] .. string.format("%.7g", bloom_knee) .. [[);
		soft = soft * soft / (4.0 * ]] .. string.format("%.7g", bloom_knee) .. [[ + 0.00001);
		float contribution = max(soft, brightness - ]] .. string.format("%.7g", bloom_threshold) .. [[);
		contribution /= max(brightness, 0.00001);
		return bloom_input * contribution;
	}

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

		float exposure = ]] .. string.format("%.7g", exposure_bootstrap) .. [[;

		if (compute.has_exposure_tex != 0) {
			exposure = clamp(
				texture(exposure_tex, vec2(0.5)).r,
				]] .. string.format("%.7g", exposure_min) .. [[,
				]] .. string.format("%.7g", exposure_max) .. [[
			);
		}

		vec3 bloom = vec3(0.0);

		if (compute.has_bloom_source_tex != 0) {
			vec2 texel_size = 1.0 / vec2(textureSize(bloom_source_tex, 0));
			bloom += texture(bloom_source_tex, uv + vec2(-1, -1) * texel_size).rgb;
			bloom += texture(bloom_source_tex, uv + vec2(0, -1) * texel_size).rgb * 2.0;
			bloom += texture(bloom_source_tex, uv + vec2(1, -1) * texel_size).rgb;
			bloom += texture(bloom_source_tex, uv + vec2(-1, 0) * texel_size).rgb * 2.0;
			bloom += texture(bloom_source_tex, uv).rgb * 4.0;
			bloom += texture(bloom_source_tex, uv + vec2(1, 0) * texel_size).rgb * 2.0;
			bloom += texture(bloom_source_tex, uv + vec2(-1, 1) * texel_size).rgb;
			bloom += texture(bloom_source_tex, uv + vec2(0, 1) * texel_size).rgb * 2.0;
			bloom += texture(bloom_source_tex, uv + vec2(1, 1) * texel_size).rgb;
			bloom /= 16.0;

			if (compute.has_bloom_merge_tex != 0) {
				bloom += extract_bloom(texture(bloom_merge_tex, uv).rgb, exposure) * ]] .. string.format("%.7g", bloom_merge_strength) .. [[;
			}
		}

		float bloom_luma = dot(bloom, vec3(0.2126, 0.7152, 0.0722)) * exposure;
		float bloom_soft_clip = 1.0 / (1.0 + bloom_luma * ]] .. string.format("%.7g", bloom_veil_soft_clip) .. [[);
		col += bloom * ]] .. string.format("%.7g", bloom_veil_strength) .. [[ * bloom_soft_clip;

		if (compute.is_hdr == 1) {
			col = tonemap_extended(col, exposure);
		} else {
			col = clamp(tonemap(col, exposure), 0.0, 1.0);
		}

		if (compute.requires_manual_gamma == 1) {
			col = LinearToSRGB(col);
		}

		imageStore(out_color, pos, vec4(col, 1.0));
	}
]]
local r = {
	exposure_feedback_pass,
	{
		name = "blit_compute",
		ComputePass = true,
		ColorFormat = {{"b10g11r11_ufloat_pack32", {"color", "rgb"}}},
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
				get_texture = get_bloom_source_texture,
			},
			{
				binding_index = 3,
				get_texture = get_bloom_merge_texture,
			},
			{
				binding_index = 4,
				get_texture = get_exposure_feedback_texture,
			},
		},
		block = {
			{"has_source_tex", "int"},
			{"is_debug_view", "int"},
			{"has_bloom_source_tex", "int"},
			{"has_bloom_merge_tex", "int"},
			{"requires_manual_gamma", "int"},
			{"is_hdr", "int"},
			{"has_exposure_tex", "int"},
		},
		write = function(self, block)
			block.has_source_tex = get_scene_source_texture() and 1 or 0
			block.is_debug_view = 0
			block.has_bloom_source_tex = get_bloom_source_texture() and 1 or 0
			block.has_bloom_merge_tex = get_bloom_merge_texture() and 1 or 0
			block.has_exposure_tex = get_exposure_feedback_texture() and 1 or 0
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
