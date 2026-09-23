local render3d = import("goluwa/render3d/render3d.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local compute_helpers = import("goluwa/render3d/compute_helpers.lua")
-- Bloom as in Jimenez 2014 (Call of Duty: Advanced Warfare). The scene is
-- halved LEVELS times with a 13 tap filter, then walked back up to half
-- resolution with a tent filter, blending each level in on the way (see
-- render3d.bloom_scatter). There is no threshold. The blit pass
-- mixes it in linearly (before exposure), so it looks the same at any
-- exposure and only what is actually bright shows a visible glow.
local LEVELS = 6
local COMPUTE_LOCAL_SIZE = {x = 8, y = 8, z = 1}
local common_glsl = compute_helpers.GetScreenHelpersGLSL() .. [[
	layout(set = 0, binding = 0, rgba16f) uniform writeonly image2D out_bloom;
	layout(set = 0, binding = 1) uniform sampler2D source_tex;

	// the attachments wrap, which would pull the opposite edge in
	vec3 bloom_sample(vec2 uv) {
		vec2 half_texel = 0.5 / vec2(textureSize(source_tex, 0));
		return textureLod(source_tex, clamp(uv, half_texel, 1.0 - half_texel), 0.0).rgb;
	}
]]
-- 13 taps over a 4x4 source texel footprint, as five overlapping 2x2 boxes.
-- The first level weighs each box by its brightness relative to the whole
-- footprint (a scale free Karis average), so a single hot pixel can't
-- flicker in and out of the pyramid as it moves between texels. It also
-- softly caps what goes in at BLOOM_MAX times white (under last frame's
-- exposure): at night the exposure rises so far that a lamp is hundreds of
-- thousands of times brighter than the scene around it, and even a few
-- percent of that would flood the screen.
local downsample_glsl = [[
	float bloom_luma(vec3 c) {
		return dot(c, vec3(0.2126, 0.7152, 0.0722));
	}

	void main() {
		ivec2 pos = get_screen_pos();
		ivec2 size = imageSize(out_bloom);

		if (!is_screen_pos_in_bounds(pos, size)) return;

		if (compute.has_source_tex == 0) {
			imageStore(out_bloom, pos, vec4(0.0));
			return;
		}

		vec2 uv = get_screen_uv(pos, size);
		vec2 t = 1.0 / vec2(textureSize(source_tex, 0));
		vec3 a = bloom_sample(uv + t * vec2(-2.0, 2.0));
		vec3 b = bloom_sample(uv + t * vec2(0.0, 2.0));
		vec3 c = bloom_sample(uv + t * vec2(2.0, 2.0));
		vec3 d = bloom_sample(uv + t * vec2(-2.0, 0.0));
		vec3 e = bloom_sample(uv);
		vec3 f = bloom_sample(uv + t * vec2(2.0, 0.0));
		vec3 g = bloom_sample(uv + t * vec2(-2.0, -2.0));
		vec3 h = bloom_sample(uv + t * vec2(0.0, -2.0));
		vec3 i = bloom_sample(uv + t * vec2(2.0, -2.0));
		vec3 j = bloom_sample(uv + t * vec2(-1.0, 1.0));
		vec3 k = bloom_sample(uv + t * vec2(1.0, 1.0));
		vec3 l = bloom_sample(uv + t * vec2(-1.0, -1.0));
		vec3 m = bloom_sample(uv + t * vec2(1.0, -1.0));
		vec3 box[5] = vec3[5](
			(j + k + l + m) * 0.25,
			(a + b + d + e) * 0.25,
			(b + c + e + f) * 0.25,
			(d + e + g + h) * 0.25,
			(e + f + h + i) * 0.25
		);
		float box_weight[5] = float[5](0.5, 0.125, 0.125, 0.125, 0.125);
		vec3 result = vec3(0.0);
		float weight_sum = 0.0;
		#ifdef KARIS
			float mean = 0.0;
			float exposure = compute.has_exposure_tex != 0 ? texture(exposure_tex, vec2(0.5)).r : 0.0;

			for (int n = 0; n < 5; n++) {
				// a NaN or inf from the scene would spread over the whole pyramid
				if (any(isnan(box[n])) || any(isinf(box[n]))) box[n] = vec3(0.0);

				box[n] = min(box[n], vec3(60000.0));
				box[n] /= 1.0 + bloom_luma(box[n]) * exposure / BLOOM_MAX;
				mean += bloom_luma(box[n]) * box_weight[n];
			}
		#endif

		for (int n = 0; n < 5; n++) {
			float w = box_weight[n];
			#ifdef KARIS
				w /= 1.0 + bloom_luma(box[n]) / max(mean, 1e-6);
			#endif
			result += box[n] * w;
			weight_sum += w;
		}

		imageStore(out_bloom, pos, vec4(result / weight_sum, 1.0));
	}
]]
-- 3x3 tent over the next smaller level, blended with this level's
-- downsample by scatter. Level n ends up weighted (1 - scatter) * scatter^n
-- (the smallest gets the remainder), so the glow is concentrated around its
-- source with a long faint tail, rather than every level counting the same and
-- a very bright source spreading into a wide flat blob. The weights sum to 1,
-- so bloom keeps the scene's energy.
local upsample_glsl = [[
	layout(set = 0, binding = 2) uniform sampler2D merge_tex;

	void main() {
		ivec2 pos = get_screen_pos();
		ivec2 size = imageSize(out_bloom);

		if (!is_screen_pos_in_bounds(pos, size)) return;

		vec2 uv = get_screen_uv(pos, size);
		vec2 t = 1.0 / vec2(textureSize(source_tex, 0));
		vec3 sum = bloom_sample(uv) * 4.0;
		sum += (
			bloom_sample(uv + t * vec2(-1.0, 0.0)) +
			bloom_sample(uv + t * vec2(1.0, 0.0)) +
			bloom_sample(uv + t * vec2(0.0, -1.0)) +
			bloom_sample(uv + t * vec2(0.0, 1.0))
		) * 2.0;
		sum += bloom_sample(uv + t * vec2(-1.0, -1.0)) +
			bloom_sample(uv + t * vec2(1.0, -1.0)) +
			bloom_sample(uv + t * vec2(-1.0, 1.0)) +
			bloom_sample(uv + t * vec2(1.0, 1.0));
		imageStore(out_bloom, pos, vec4(mix(texelFetch(merge_tex, pos, 0).rgb, sum / 16.0, compute.scatter), 1.0));
	}
]]

local function get_pipeline_texture(name)
	return function()
		return render3d.pipelines[name]:GetFramebuffer():GetAttachment(1)
	end
end

render3d.bloom_scatter = 0.7

local function build_pass(name, scale, shader, sampled_images)
	return {
		name = name,
		ComputePass = true,
		ColorFormat = {{"r16g16b16a16_sfloat", {"bloom", "rgba"}}},
		scale = scale,
		LocalSize = COMPUTE_LOCAL_SIZE,
		storage_images = {{binding_index = 0, attachment = 1, dst_stage = "compute"}},
		sampled_images = sampled_images,
		block = {
			{"has_source_tex", "int"},
			{"has_exposure_tex", "int"},
			{"scatter", "float"},
		},
		write = function(self, block)
			block.has_source_tex = sampled_images[1].get_texture() and 1 or 0
			block.has_exposure_tex = sampled_images[2] and sampled_images[2].get_texture() and 1 or 0
			block.scatter = render3d.bloom_scatter
			return block
		end,
		shader = shader,
	}
end

local r = {}

for i = 1, LEVELS do
	local get_source_texture = i == 1 and
		function()
			return post_source.GetSceneSourceTexture({name = "bloom_down1"})
		end or
		get_pipeline_texture("bloom_down" .. (i - 1))
	r[#r + 1] = build_pass(
		"bloom_down" .. i,
		0.5 ^ i,
		(
				i == 1 and
				"#define KARIS\n#define BLOOM_MAX 32.0\nlayout(set = 0, binding = 2) uniform sampler2D exposure_tex;\n" or
				""
			) .. common_glsl .. downsample_glsl,
		{
			{binding_index = 1, get_texture = get_source_texture},
			i == 1 and
			{
				binding_index = 2,
				get_texture = function()
					return post_source.GetExposureTexture(true)
				end,
			} or
			nil,
		}
	)
end

for i = LEVELS - 1, 1, -1 do
	r[#r + 1] = build_pass(
		"bloom_up" .. i,
		0.5 ^ i,
		common_glsl .. upsample_glsl,
		{
			{
				binding_index = 1,
				get_texture = get_pipeline_texture(i == LEVELS - 1 and "bloom_down" .. LEVELS or "bloom_up" .. (i + 1)),
			},
			{binding_index = 2, get_texture = get_pipeline_texture("bloom_down" .. i)},
		}
	)
end

return r
