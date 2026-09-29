local render = import("goluwa/render/render.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local system = import("goluwa/system.lua")
local commands = import("goluwa/cli/commands.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local compute_helpers = import("goluwa/render3d/compute_helpers.lua")
-- Glare: the light scattered inside the eye. Stiles and Holladay's disability
-- glare puts a veil of 10 E / theta^2 cd/m2 at theta degrees from a source
-- that lights the eye with E lux. That is linear in the light, so it is there
-- for every pixel, but a normal scene only loses a little contrast to it,
-- while the sun or a glint of it, thousands of times brighter than anything
-- around, drowns everything within a few degrees in its glow.
--
-- 1 / theta^2 over the area around the source is the same energy in every
-- octave of angle, 0.0191 ln 2 of the light. The scene is halved LEVELS times
-- with a 13 tap filter (Jimenez 2014, Call of Duty: Advanced Warfare), each
-- level blurring over twice the angle of the last, then walked back up with a
-- tent filter, adding each level in with the energy of the octave it covers.
-- The levels are measured in degrees through the camera's field of view, so
-- the glare is the same size on screen at any fov or resolution. The blit
-- pass mixes it in linearly (before exposure) by the total weight.
local LEVELS = 10
local COMPUTE_LOCAL_SIZE = {x = 8, y = 8, z = 1}
local ENERGY_PER_OCTAVE = 0.0191 * math.log(2)
-- the range CIE 146's glare spread function is fitted over is 0.1 to 100 degrees.
-- past 30 the veil is spread evenly over most of the screen anyway
local MIN_DEGREES = 0.1
local MAX_DEGREES = 30
render3d.bloom_strength = 1
-- how long in seconds a bright highlight's glare lingers where it was on screen,
-- smearing it along the way when it or the camera moves (see passes/blit.lua).
-- 0 is off
render3d.bloom_smear = 0.1

commands.Add("r_bloom_strength=number[1]", function(value)
	render3d.bloom_strength = value
end)

commands.Add("r_bloom_smear=number[0.1]", function(value)
	render3d.bloom_smear = value
end)

-- the weight each level is added in with, normalized, and their total
do
	local weights = {}
	local total = 0
	local last_frame = -1

	function render3d.GetBloomWeights()
		local frame = system.GetFrameNumber()

		if frame == last_frame then return weights, total end

		last_frame = frame
		-- full resolution pixels per degree at the center of the screen
		local pixels_per_degree = render.GetRenderImageSize().y / 2 / math.tan(render3d.GetCamera():GetFOV() / 2) * math.pi / 180
		total = 0

		for i = 1, LEVELS do
			-- level i blurs over about 2^i pixels, the octave around it
			local degrees = 2 ^ i / pixels_per_degree
			local low = math.log(math.max(degrees / math.sqrt(2), MIN_DEGREES)) / math.log(2)
			local high = math.log(math.min(degrees * math.sqrt(2), MAX_DEGREES)) / math.log(2)
			weights[i] = math.max(high - low, 0) * ENERGY_PER_OCTAVE
			total = total + weights[i]
		end

		for i = 1, LEVELS do
			weights[i] = weights[i] / total
		end

		return weights, total
	end
end

local common_glsl = compute_helpers.GetScreenHelpersGLSL() .. [[
	layout(set = 0, binding = 0, rgba16f) uniform writeonly image2D out_bloom;
	layout(set = 0, binding = 1) uniform sampler2D source_tex;

	#ifdef ADAPT
		// set by main, what the scene is exposed with and the exposure texture
		float adapt_exposure;
		vec4 adapt_exposure_sample;
	#endif

	// the attachments wrap, which would pull the opposite edge in
	vec3 bloom_sample(vec2 uv) {
		vec2 half_texel = 0.5 / vec2(textureSize(source_tex, 0));
		uv = clamp(uv, half_texel, 1.0 - half_texel);
		vec3 c = textureLod(source_tex, uv, 0.0).rgb;
		#ifdef ADAPT
			// glare comes from the light as the eye adapted to it: a region it
			// adapted down scatters that much less. lifted shadows don't add any
			if (compute.has_grid_tex != 0) {
				c *= exp2(min(get_local_adaptation(uv, dot(c, vec3(0.2126, 0.7152, 0.0722)) * adapt_exposure, adapt_exposure_sample), 0.0));
			}
		#endif
		return c;
	}
]]
-- 13 taps over a 4x4 source texel footprint, as five overlapping 2x2 boxes.
-- No Karis average: it keeps a hot pixel from flickering by weighing boxes
-- down by their brightness, which throws away most of the sun and its glints,
-- the very things the glare is for. For the same reason the glare comes from
-- the scene before TAA, whose blend on compressed colour loses half of the
-- sun's disc. The blur hides the jitter and the smear (passes/blit.lua) keeps
-- it steady.
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
		#ifdef ADAPT
			adapt_exposure_sample = texture(exposure_tex, vec2(0.5));
			// the scene is pre-exposed with last frame's exposure
			adapt_exposure = adapt_exposure_sample.r / pre_exposure_from_exposure(texture(prev_exposure_tex, vec2(0.5)).r);
		#endif
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

		// a NaN or inf from the scene would spread over the whole pyramid
		if (any(isnan(result)) || any(isinf(result))) result = vec3(0.0);

		imageStore(out_bloom, pos, vec4(result, 1.0));
	}
]]
-- 3x3 tent over the next smaller level, plus this level's downsample by its
-- weight. The smallest level comes in by its own weight.
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
		imageStore(out_bloom, pos, vec4(sum / 16.0 * compute.source_weight + texelFetch(merge_tex, pos, 0).rgb * compute.merge_weight, 1.0));
	}
]]

local function get_pipeline_texture(name)
	return function()
		return render3d.pipelines[name]:GetFramebuffer():GetAttachment(1)
	end
end

local block = {
	{"has_source_tex", "int"},
	{"source_weight", "float"},
	{"merge_weight", "float"},
}

local function build_pass(name, scale, shader, sampled_images, write, extra_block)
	return {
		name = name,
		ComputePass = true,
		ColorFormat = {{"r16g16b16a16_sfloat", {"bloom", "rgba"}}},
		scale = scale,
		LocalSize = COMPUTE_LOCAL_SIZE,
		storage_images = {{binding_index = 0, attachment = 1, dst_stage = "compute"}},
		sampled_images = sampled_images,
		block = extra_block and {block, extra_block} or block,
		write = function(self, block)
			block.has_source_tex = sampled_images[1].get_texture() and 1 or 0

			if write then write(block) end

			return block
		end,
		shader = shader,
	}
end

-- The passes, given the eye's local adaptation for the first downsample
-- (see passes/blit.lua): glsl declaring grid_tex (binding 2), exposure_tex (3)
-- and prev_exposure_tex (4) and defining get_local_adaptation, textures for
-- those bindings, and the block and its writer that function reads.
return function(adaptation)
	local r = {}

	for i = 1, LEVELS do
		if i == 1 then
			local sampled_images = {
				{
					binding_index = 1,
					get_texture = function()
						return post_source.GetRawSceneSourceTexture()
					end,
				},
			}

			for _, info in ipairs(adaptation.sampled_images) do
				sampled_images[#sampled_images + 1] = info
			end

			r[#r + 1] = build_pass(
				"bloom_down1",
				0.5,
				"#define ADAPT\n" .. adaptation.glsl .. common_glsl .. downsample_glsl,
				sampled_images,
				adaptation.write,
				adaptation.block
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
				block.source_weight = i == LEVELS - 1 and weights[LEVELS] or 1
				block.merge_weight = weights[i]
			end
		)
	end

	return r
end
