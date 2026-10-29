local render = import("goluwa/render/render.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local system = import("goluwa/system.lua")
local pvars = import("goluwa/cli/pvars.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local compute_helpers = import("goluwa/render3d/compute_helpers.lua")
local exposure_model = import("goluwa/render3d/exposure.lua")
local eye_glare = import("goluwa/render3d/eye_glare.lua")
local LEVELS = 10
local COMPUTE_LOCAL_SIZE = {x = 8, y = 8, z = 1}
local ENERGY_PER_OCTAVE = 0.0191 * math.log(2)
local MIN_DEGREES = 0.1
local MAX_DEGREES = 30
pvars.StartGroup("Post", "Bloom", {store = false, prefix = "bloom_"})
render3d.bloom_strength = pvars.Setup2{
	key = "r_bloom_strength",
	default = 1,
	min = 0,
	help = "scales the share of the light the glare takes",
}
render3d.eye_chromatic_halo = pvars.Setup2{
	key = "r_eye_chromatic_halo",
	default = true,
	help = "in eye mode the glare depends on wavelength: the core spreads in proportion to it (diffraction) and the wide veil scatters more for blue (1/wavelength^4), which leaves a coloured fringe around white lights",
}
pvars.EndGroup()

do
	local weights = {{}, {}, {}}
	local totals = {0, 0, 0}
	local last_frame = -1

	function render3d.GetBloomWeights()
		local frame = system.GetFrameNumber()

		if frame == last_frame then return weights, totals end

		last_frame = frame
		local pixels_per_degree = exposure_model.GetPixelsPerDegree(render.GetRenderImageSize().y)
		local eye = exposure_model.IsEye()
		local chromatic = eye and render3d.eye_chromatic_halo:Get()
		local sums = {0, 0, 0}

		for i = 1, LEVELS do
			local degrees = 2 ^ i / pixels_per_degree
			local low = math.log(math.max(degrees / math.sqrt(2), MIN_DEGREES)) / math.log(2)
			local high = math.log(math.min(degrees * math.sqrt(2), MAX_DEGREES)) / math.log(2)

			for channel = 1, 3 do
				local weight = 0

				if high > low then
					if eye then
						weight = eye_glare.GetBandEnergy(
							low,
							high,
							chromatic and
								eye_glare.CHANNEL_WAVELENGTH[channel] / eye_glare.REFERENCE_WAVELENGTH or
								1
						)
					else
						weight = (high - low) * ENERGY_PER_OCTAVE
					end
				end

				weights[channel][i] = weight
				sums[channel] = sums[channel] + weight
			end
		end

		for channel = 1, 3 do
			for i = 1, LEVELS do
				weights[channel][i] = weights[channel][i] / sums[channel]
			end
		end

		totals[1], totals[2], totals[3] = sums[1], sums[2], sums[3]
		return weights, totals
	end
end

local common_glsl = compute_helpers.GetScreenHelpersGLSL() .. [[
	layout(set = 0, binding = 0, rgba16f) uniform writeonly image2D out_bloom;
	layout(set = 0, binding = 1) uniform sampler2D source_tex;

	#ifdef BLOOM_EFFECT_LAYER
	layout(set = 0, binding = 3) uniform sampler2D layer_tex;
	#endif

	vec3 bloom_sample(vec2 uv) {
		vec2 half_texel = 0.5 / vec2(textureSize(source_tex, 0));
		uv = clamp(uv, half_texel, 1.0 - half_texel);
		vec3 color = textureLod(source_tex, uv, 0.0).rgb;
		#ifdef BLOOM_EFFECT_LAYER
		if (compute.has_layer != 0) color += textureLod(layer_tex, uv, 0.0).rgb;
		#endif
		return color;
	}
]]
local downsample_glsl = [[
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
		vec3 result = (box[0] * 0.5 + (box[1] + box[2] + box[3] + box[4]) * 0.125);

		if (any(isnan(result)) || any(isinf(result))) result = vec3(0.0);

		imageStore(out_bloom, pos, vec4(result, 1.0));
	}
]]
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
		imageStore(out_bloom, pos, vec4(sum / 16.0 * compute.source_weight.rgb + texelFetch(merge_tex, pos, 0).rgb * compute.merge_weight.rgb, 1.0));
	}
]]

local function get_pipeline_texture(name)
	return function()
		return render3d.pipelines[name]:GetFramebuffer():GetAttachment(1)
	end
end

local block = {
	{"has_source_tex", "int"},
	{"has_layer", "int"},
	{"source_weight", "vec4"},
	{"merge_weight", "vec4"},
}

local function build_pass(name, scale, shader, sampled_images, write)
	return {
		name = name,
		ComputePass = true,
		ColorFormat = {{"r16g16b16a16_sfloat", {"bloom", "rgba"}}},
		scale = scale,
		LocalSize = COMPUTE_LOCAL_SIZE,
		storage_images = {{binding_index = 0, attachment = 1, dst_stage = "compute"}},
		sampled_images = sampled_images,
		block = block,
		write = function(self, block)
			block.has_source_tex = sampled_images[1].get_texture() and 1 or 0

			if write then write(block) end

			return block
		end,
		shader = shader,
	}
end

return function()
	local r = {}

	for i = 1, LEVELS do
		if i == 1 then
			r[#r + 1] = build_pass(
				"bloom_down1",
				0.5,
				"#define BLOOM_EFFECT_LAYER\n" .. common_glsl .. downsample_glsl,
				{
					{
						binding_index = 1,
						get_texture = function()
							return post_source.GetRawSceneSourceTexture()
						end,
					},
					{
						binding_index = 3,
						get_texture = function()
							return post_source.IsEffectLayerActive() and
								post_source.GetEffectLayerTexture() or
								post_source.GetRawSceneSourceTexture()
						end,
					},
				},
				function(block)
					block.has_layer = post_source.IsEffectLayerActive() and 1 or 0
				end
			)
		else
			r[#r + 1] = build_pass(
				"bloom_down" .. i,
				0.5 ^ i,
				common_glsl .. downsample_glsl,
				{
					{binding_index = 1, get_texture = get_pipeline_texture("bloom_down" .. (i - 1))},
				}
			)
		end
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
				{
					binding_index = 2,
					get_texture = get_pipeline_texture("bloom_down" .. i),
				},
			},
			function(block)
				local weights = render3d.GetBloomWeights()

				for channel = 0, 2 do
					block.source_weight[channel] = i == LEVELS - 1 and weights[channel + 1][LEVELS] or 1
					block.merge_weight[channel] = weights[channel + 1][i]
				end
			end
		)
	end

	return r
end
