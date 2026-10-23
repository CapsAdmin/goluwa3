local render = import("goluwa/render/render.lua")
local system = import("goluwa/system.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local pvars = import("goluwa/cli/pvars.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local screen_reconstruct = import("goluwa/render3d/screen_reconstruct.lua")
local compute_helpers = import("goluwa/render3d/compute_helpers.lua")
local exposure_model = import("goluwa/render3d/exposure.lua")
local eye_glare = import("goluwa/render3d/eye_glare.lua")
local eye_psf = import("goluwa/render3d/eye_psf.lua")
local Texture = import("goluwa/render/texture.lua")
local COMPUTE_LOCAL_SIZE = {x = 8, y = 8, z = 1}
local TILE_SCALE = 1 / 16
local SPREAD_WINDOW = 16
local COMPACT_SPREAD = 6
local MAX_DEGREES = 10
local HISTORY_WEIGHT = 0.9
local SPREAD_ENTRIES = 256
local SPREAD_MIN_DEGREES = 0.05
local SPREAD_MAX_DEGREES = 30
pvars.StartGroup("Post", "Eye effects", {store = false})
render3d.starburst_enabled = pvars.Setup2{
	key = "r_eye_starburst",
	default = true,
	help = "in eye mode bright lights get the diffraction pattern of the eye's pupil, lens sutures and lashes, the rays of a star around the light, added to the smooth glare",
}
pvars.EndGroup()
local textures

local function get_textures()
	if textures then return textures end

	local function make(width, height, format, data)
		return Texture.New{
			width = width,
			height = height,
			format = format,
			buffer = data,
			image = {usage = {"storage", "sampled", "transfer_src", "transfer_dst"}},
			sampler = {
				min_filter = "linear",
				mag_filter = "linear",
				wrap_s = "repeat",
				wrap_t = "clamp_to_edge",
			},
		}
	end

	textures = {
		modulation = make(
			eye_psf.ANGLES,
			eye_psf.RADII,
			"r32_sfloat",
			eye_psf.BuildModulation(eye_psf.BuildSpectrum())
		),
		spread = make(
			SPREAD_ENTRIES,
			1,
			"r32g32b32a32_sfloat",
			eye_psf.BuildSpreadTable(SPREAD_ENTRIES, SPREAD_MIN_DEGREES, SPREAD_MAX_DEGREES)
		),
	}
	return textures
end

function render3d.IsStarburstEnabled()
	return exposure_model.IsEye() and render3d.starburst_enabled:Get()
end

local is_enabled = render3d.IsStarburstEnabled

local function get_tile_texture(attachment)
	return function()
		local pipeline = render3d.pipelines.starburst_tiles
		return pipeline and
			pipeline.framebuffers and
			pipeline:GetFramebuffer():GetAttachment(attachment) or
			nil
	end
end

local last_frame, last_width, last_height = -1, 0, 0
local ratios = {}

for i, wavelength in ipairs(eye_glare.CHANNEL_WAVELENGTH) do
	ratios[i] = string.format("%.6f", wavelength / eye_glare.REFERENCE_WAVELENGTH)
end

return {
	{
		name = "starburst_tiles",
		is_enabled = is_enabled,
		ComputePass = true,
		ColorFormat = {
			{"r32g32b32a32_sfloat", {"star_tile_sum", "rgba"}},
			{"r32g32b32a32_sfloat", {"star_tile_centroid", "rgba"}},
		},
		framebuffer_count = 1,
		scale = TILE_SCALE,
		LocalSize = COMPUTE_LOCAL_SIZE,
		storage_images = {
			{binding_index = 0, attachment = 1, dst_stage = "compute"},
			{binding_index = 1, attachment = 2, dst_stage = "compute"},
		},
		sampled_images = {
			{
				binding_index = 2,
				get_texture = function()
					return render3d.pipelines.bloom_down1:GetFramebuffer():GetAttachment(1)
				end,
			},
			{
				binding_index = 3,
				get_texture = function()
					return render3d.pipelines.bloom_down4:GetFramebuffer():GetAttachment(1)
				end,
			},
		},
		block = {{"unused", "int"}},
		write = function(self, block)
			return block
		end,
		shader = [[
			layout(set = 0, binding = 0, rgba32f) uniform writeonly image2D out_sum;
			layout(set = 0, binding = 1, rgba32f) uniform writeonly image2D out_centroid;
			layout(set = 0, binding = 2) uniform sampler2D source_tex;
			layout(set = 0, binding = 3) uniform sampler2D background_tex;
			const vec2 SPREAD_WINDOW = vec2(]] .. SPREAD_WINDOW .. [[.0);
			const float COMPACT_SPREAD = ]] .. COMPACT_SPREAD .. [[.0;
		]] .. compute_helpers.GetScreenHelpersGLSL() .. [[
			void main() {
				ivec2 pos = get_screen_pos();
				ivec2 size = imageSize(out_sum);

				if (!is_screen_pos_in_bounds(pos, size)) return;

				ivec2 source_size = textureSize(source_tex, 0);
				vec2 per_tile = vec2(source_size) / vec2(size);
				vec2 middle = (vec2(pos) + 0.5) * per_tile;
				ivec2 low = max(ivec2(floor(middle - SPREAD_WINDOW)), ivec2(0));
				ivec2 high = min(ivec2(ceil(middle + SPREAD_WINDOW)), source_size);
				vec3 sum = vec3(0.0);
				float weight = 0.0;
				vec2 weighted_position = vec2(0.0);
				float spread_weight = 0.0;
				vec2 spread_first = vec2(0.0);
				float spread_second = 0.0;

				for (int y = low.y; y < high.y; y++) {
					for (int x = low.x; x < high.x; x++) {
						vec2 at = vec2(x, y) + 0.5;
						vec3 excess = max(texelFetch(source_tex, ivec2(x, y), 0).rgb - textureLod(background_tex, at / vec2(source_size), 0.0).rgb, vec3(0.0));
						float l = luminance(excess);

						if (l <= 0.0) continue;

						vec2 relative = at - middle;
						spread_weight += l;
						spread_first += l * relative;
						spread_second += l * dot(relative, relative);
						vec2 tent = max(1.0 - abs(relative) / per_tile, vec2(0.0));
						float share = tent.x * tent.y;
						sum += excess * share;
						weight += l * share;
						weighted_position += l * share * at / vec2(source_size);
					}
				}

				float spread = 0.0;

				if (spread_weight > 0.0) {
					vec2 mean = spread_first / spread_weight;
					spread = sqrt(max(spread_second / spread_weight - dot(mean, mean), 0.0));
				}

				float compact = 1.0 - smoothstep(COMPACT_SPREAD, 2.0 * COMPACT_SPREAD, spread);
				sum *= compact;
				weight *= compact;
				imageStore(out_sum, pos, vec4(sum, weight));
				imageStore(out_centroid, pos, vec4(weight > 0.0 ? weighted_position / (weight / compact) : vec2(0.0), weight, 0.0));
			}
		]],
	},
	{
		name = "starburst",
		is_enabled = is_enabled,
		ComputePass = true,
		ColorFormat = {{"r16g16b16a16_sfloat", {"starburst", "rgba"}}},
		framebuffer_count = 2,
		scale = 0.5,
		LocalSize = COMPUTE_LOCAL_SIZE,
		storage_images = {{binding_index = 0, attachment = 1, dst_stage = "compute"}},
		sampled_images = {
			{binding_index = 1, get_texture = get_tile_texture(1)},
			{binding_index = 2, get_texture = get_tile_texture(2)},
			{
				binding_index = 3,
				get_texture = function()
					return get_textures().modulation
				end,
			},
			{
				binding_index = 4,
				get_texture = function()
					return get_textures().spread
				end,
			},
			{
				binding_index = 5,
				get_texture = function()
					return post_source.GetExposureTexture()
				end,
			},
			{
				binding_index = 6,
				get_texture = function()
					return post_source.GetExposureTexture(true)
				end,
			},
			{
				binding_index = 7,
				get_texture = function()
					return render3d.pipelines.starburst:GetFramebuffer((system.GetFrameNumber() + 1) % 2 + 1):GetAttachment(1)
				end,
			},
		},
		uniform_buffers = {
			{
				name = "star_data",
				binding_index = 8,
				block = {
					render3d.camera_block,
					render3d.prev_camera_block,
					{"history_weight", "float"},
					{"jitter", "vec2"},
					{"pixels_per_degree", "float"},
					{"strength", "float"},
				},
				write = function(self, block)
					local frame = system.GetFrameNumber()
					local size = render.GetRenderImageSize()
					render3d.WriteCameraBlock(self, block)
					render3d.WritePreviousCameraBlock(self, block)
					block.history_weight = render3d.IsTemporalAntiAliasingEnabled() and
						last_frame == frame - 1 and
						last_width == size.x and
						last_height == size.y and
						HISTORY_WEIGHT or
						0
					last_frame, last_width, last_height = frame, size.x, size.y
					block.pixels_per_degree = exposure_model.GetPixelsPerDegree(size.y) / 2
					block.strength = render3d.bloom_strength:Get()
					local jitter = render3d.GetCamera():GetJitter()
					block.jitter[0] = jitter.x
					block.jitter[1] = jitter.y
					return block
				end,
			},
		},
		shader = [[
			layout(set = 0, binding = 0, rgba16f) uniform writeonly image2D out_star;
			layout(set = 0, binding = 1) uniform sampler2D tile_sum_tex;
			layout(set = 0, binding = 2) uniform sampler2D tile_centroid_tex;
			layout(set = 0, binding = 3) uniform sampler2D modulation_tex;
			layout(set = 0, binding = 4) uniform sampler2D spread_tex;
			layout(set = 0, binding = 5) uniform sampler2D exposure_tex;
			layout(set = 0, binding = 6) uniform sampler2D prev_exposure_tex;
			layout(set = 0, binding = 7) uniform sampler2D history_tex;
			const vec3 CHANNEL_RATIO = vec3(]] .. table.concat(ratios, ", ") .. [[);
			const float MAX_DEGREES = ]] .. MAX_DEGREES .. [[.0;
			const float PUPIL_REFERENCE_MM = ]] .. string.format("%.3f", eye_psf.PUPIL_DIAMETER * 1000) .. [[;
			const float SPREAD_LOG_MIN = ]] .. string.format("%.6f", math.log(SPREAD_MIN_DEGREES)) .. [[;
			const float SPREAD_LOG_RANGE = ]] .. string.format("%.6f", math.log(SPREAD_MAX_DEGREES) - math.log(SPREAD_MIN_DEGREES)) .. [[;
			const float PSF_LOG_MIN = ]] .. string.format("%.6f", math.log(eye_psf.MIN_DEGREES)) .. [[;
			const float PSF_LOG_RANGE = ]] .. string.format("%.6f", math.log(eye_psf.GetMaxDegrees()) - math.log(eye_psf.MIN_DEGREES)) .. [[;
			const float SOURCE_THRESHOLD = 4.0;
			const float TURN_STILL_PIXELS = 0.35;
			const float TRAVEL_STILL_METERS = 0.004;
			const vec2 JITTER_SIGN = vec2(-1.0, -1.0);
		]] .. post_source.GetPreExposureFromExposureGLSL() .. compute_helpers.GetScreenHelpersGLSL() .. screen_reconstruct.GetViewRayFromUVGLSL("star_data") .. [[
			void main() {
				ivec2 pos = get_screen_pos();
				ivec2 size = imageSize(out_star);

				if (!is_screen_pos_in_bounds(pos, size)) return;

				float exposure = texture(exposure_tex, vec2(0.5)).r / pre_exposure_from_exposure(texture(prev_exposure_tex, vec2(0.5)).r);
				float adapting_log10 = (texture(exposure_tex, vec2(0.5)).b - 3.0) * 0.30103;
				float pupil_scale = (4.9 - 3.0 * tanh(0.4 * (adapting_log10 + 1.0))) / PUPIL_REFERENCE_MM;
				ivec2 tiles = textureSize(tile_sum_tex, 0);
				vec2 per_tile = vec2(size) / vec2(tiles);
				ivec2 home = ivec2(vec2(pos) / per_tile);
				int reach = int(ceil(MAX_DEGREES * star_data.pixels_per_degree / min(per_tile.x, per_tile.y)));
				float solid_angle = pow(radians(1.0 / star_data.pixels_per_degree), 2.0);
				vec3 star = vec3(0.0);

				for (int ty = -reach; ty <= reach; ty++) {
					for (int tx = -reach; tx <= reach; tx++) {
						ivec2 tile = home + ivec2(tx, ty);

						if (any(lessThan(tile, ivec2(0))) || any(greaterThanEqual(tile, tiles))) continue;

						vec4 tile_sum = texelFetch(tile_sum_tex, tile, 0);

						if (tile_sum.a * exposure < SOURCE_THRESHOLD) continue;

						vec2 offset = vec2(pos) + 0.5 - (texelFetch(tile_centroid_tex, tile, 0).xy * vec2(size) + JITTER_SIGN * 0.5 * star_data.jitter);
						float degrees = length(offset) / star_data.pixels_per_degree;
						float ramp = smoothstep(0.2, 0.8, degrees) * (1.0 - smoothstep(0.7 * MAX_DEGREES, MAX_DEGREES, degrees));

						if (ramp <= 0.0) continue;

						float angle = atan(offset.y, offset.x) / 6.2831853 + 0.5;
						vec3 spread = texture(spread_tex, vec2((log(degrees) - SPREAD_LOG_MIN) / SPREAD_LOG_RANGE, 0.5)).rgb;
						vec3 scaled_log = log(degrees * pupil_scale / CHANNEL_RATIO);
						vec3 modulation = vec3(
							texture(modulation_tex, vec2(angle, (scaled_log.r - PSF_LOG_MIN) / PSF_LOG_RANGE)).r,
							texture(modulation_tex, vec2(angle, (scaled_log.g - PSF_LOG_MIN) / PSF_LOG_RANGE)).r,
							texture(modulation_tex, vec2(angle, (scaled_log.b - PSF_LOG_MIN) / PSF_LOG_RANGE)).r
						);
						star += tile_sum.rgb * solid_angle * spread * max(modulation - 1.0, vec3(0.0)) * ramp;
					}
				}

				star *= star_data.strength;

				if (star_data.history_weight > 0.0) {
					vec4 previous_clip = star_data.prev_projection * mat4(mat3(star_data.prev_view)) * vec4(get_view_ray((vec2(pos) + 0.5) / vec2(size)), 1.0);
					vec2 previous_uv = previous_clip.xy / previous_clip.w * 0.5 + 0.5;

					if (previous_clip.w > 0.0 && all(greaterThanEqual(previous_uv, vec2(0.0))) && all(lessThanEqual(previous_uv, vec2(1.0)))) {
						vec2 uv = (vec2(pos) + 0.5) / vec2(size);
						float turned = length((uv - previous_uv) * vec2(size));
						float travelled = length(inverse(star_data.prev_view)[3].xyz - star_data.inv_view[3].xyz);
						float still = (1.0 - smoothstep(TURN_STILL_PIXELS, 4.0 * TURN_STILL_PIXELS, turned)) * (1.0 - smoothstep(TRAVEL_STILL_METERS, 8.0 * TRAVEL_STILL_METERS, travelled));
						star = mix(star, texture(history_tex, edge_clamp_uv(previous_uv, textureSize(history_tex, 0))).rgb, star_data.history_weight * still);
					}
				}

				imageStore(out_star, pos, vec4(star, 1.0));
			}
		]],
	},
}
