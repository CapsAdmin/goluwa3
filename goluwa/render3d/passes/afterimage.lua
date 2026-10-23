local render = import("goluwa/render/render.lua")
local system = import("goluwa/system.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local pvars = import("goluwa/cli/pvars.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local gbuffer_layout = import("goluwa/render3d/gbuffer_layout.lua")
local screen_reconstruct = import("goluwa/render3d/screen_reconstruct.lua")
local compute_helpers = import("goluwa/render3d/compute_helpers.lua")
local exposure_model = import("goluwa/render3d/exposure.lua")
local afterimage = {}
local COMPUTE_LOCAL_SIZE = {x = 8, y = 8, z = 1}
local HALF_BLEACH_LUMINANCE = 4000
local RECOVERY_SECONDS = 16
local CYCLE_SECONDS = 8
local POSITIVE_LEVEL = 0.5
local SOURCE_LEVEL = 0.8
local HALF_SOURCE_LUMINANCE = 3000
local MAX_PATH_STEPS = 32
local MAX_MOTION = 0.2
local BLUR_SPACING = 1.2
pvars.StartGroup("Post", "Eye effects", {store = false})
render3d.afterimage_enabled = pvars.Setup2{
	key = "r_eye_afterimage",
	default = true,
	help = "in eye mode bright lights leave an afterimage on the retina: a coloured glow that changes hue over time (green, blue, purple, then red, as the three cone types fall silent at different speeds) with a darker, complementary tinted patch under it. It sits on the screen like a real afterimage, so it follows the view, and a light sweeping across it leaves a streak",
}
pvars.EndGroup()

function afterimage.IsEnabled()
	return exposure_model.IsEye() and
		render3d.afterimage_enabled:Get() and
		exposure_model.Get("eye.afterimage_intensity") > 0
end

local function multiply(a, b)
	local out = {}

	for i = 1, 3 do
		out[i] = {}

		for j = 1, 3 do
			out[i][j] = a[i][1] * b[1][j] + a[i][2] * b[2][j] + a[i][3] * b[3][j]
		end
	end

	return out
end

local function invert(m)
	local a, b, c, d, e, f, g, h, i = m[1][1], m[1][2], m[1][3], m[2][1], m[2][2], m[2][3], m[3][1], m[3][2], m[3][3]
	local det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
	return {
		{
			(
				e * i - f * h
			) / det,
			(
				c * h - b * i
			) / det,
			(
				b * f - c * e
			) / det,
		},
		{
			(
				f * g - d * i
			) / det,
			(
				a * i - c * g
			) / det,
			(
				c * d - a * f
			) / det,
		},
		{
			(
				d * h - e * g
			) / det,
			(
				b * g - a * h
			) / det,
			(
				a * e - b * d
			) / det,
		},
	}
end

local function glsl_matrix(name, m)
	local values = {}

	for column = 1, 3 do
		for row = 1, 3 do
			values[#values + 1] = string.format("%.7f", m[row][column])
		end
	end

	return string.format("const mat3 %s = mat3(%s);\n", name, table.concat(values, ", "))
end

local srgb_to_xyz = {
	{0.4124564, 0.3575761, 0.1804375},
	{0.2126729, 0.7151522, 0.0721750},
	{0.0193339, 0.1191920, 0.9503041},
}
local xyz_to_cones = {
	{0.38971, 0.68898, -0.07868},
	{-0.22981, 1.18340, 0.04641},
	{0, 0, 1},
}
local rgb_to_cones = multiply(xyz_to_cones, srgb_to_xyz)

function afterimage.GetApplyGLSL()
	return glsl_matrix("RGB_TO_CONES", rgb_to_cones) .. glsl_matrix("CONES_TO_RGB", invert(rgb_to_cones)) .. [[
		vec3 afterimage_ramp(float age) {
			const vec3 colors[6] = vec3[6](
				vec3(1.0, 1.0, 1.0),
				vec3(1.0, 0.85, 0.1),
				vec3(0.1, 1.0, 0.2),
				vec3(0.1, 0.35, 1.0),
				vec3(0.8, 0.15, 1.0),
				vec3(1.0, 0.08, 0.05)
			);
			const float stops[6] = float[6](0.0, 0.1, 0.22, 0.36, 0.5, 0.66);
			vec3 color = colors[0];

			for (int i = 1; i < 6; i++) color = mix(color, colors[i], smoothstep(stops[i - 1], stops[i], age));

			return color;
		}

		vec3 apply_afterimage(vec3 col, vec3 excitation, vec3 bleach, vec4 source, float exposure, float intensity) {
			float level = clamp(excitation.r, 0.0, 1.0);
			vec3 negative = max(CONES_TO_RGB * (RGB_TO_CONES * col * (1.0 - clamp(bleach * intensity, vec3(0.0), vec3(1.0)))), vec3(0.0));
			vec3 source_glow = max(CONES_TO_RGB * source.rgb, vec3(0.0)) * ]] .. string.format("%.4f", SOURCE_LEVEL / POSITIVE_LEVEL) .. [[;
			vec3 cycle_glow = afterimage_ramp(1.0 - level) * (0.25 + 0.75 * level) * smoothstep(0.0, 0.1, level) * (1.0 - clamp(source.a, 0.0, 1.0));
			return negative + (source_glow + cycle_glow) * intensity * ]] .. POSITIVE_LEVEL .. [[ / max(exposure, 1e-6);
		}
	]]
end

local last_frame, last_width, last_height = -1, 0, 0

local function get_current(attachment)
	return function()
		return render3d.pipelines.afterimage:GetFramebuffer(system.GetFrameNumber() % 2 + 1):GetAttachment(attachment)
	end
end

local function get_history(attachment)
	return function()
		return render3d.pipelines.afterimage:GetFramebuffer((system.GetFrameNumber() + 1) % 2 + 1):GetAttachment(attachment)
	end
end

afterimage.passes = {
	{
		name = "afterimage",
		is_enabled = afterimage.IsEnabled,
		ComputePass = true,
		ColorFormat = {
			{"r16g16b16a16_sfloat", {"afterimage", "rgba"}},
			{"r16g16b16a16_sfloat", {"afterimage_bleach", "rgba"}},
			{"r16g16b16a16_sfloat", {"afterimage_source", "rgba"}},
		},
		framebuffer_count = 2,
		scale = 0.125,
		LocalSize = COMPUTE_LOCAL_SIZE,
		storage_images = {
			{binding_index = 0, attachment = 1, dst_stage = "compute"},
			{binding_index = 1, attachment = 2, dst_stage = "compute"},
			{binding_index = 8, attachment = 3, dst_stage = "compute"},
		},
		sampled_images = {
			{binding_index = 9, get_texture = get_history(3)},
			{
				binding_index = 2,
				get_texture = function()
					return render3d.pipelines.bloom_down3:GetFramebuffer():GetAttachment(1)
				end,
			},
			{
				binding_index = 3,
				get_texture = function()
					return render3d.pipelines.glare:GetFramebuffer():GetAttachment(1)
				end,
			},
			{binding_index = 4, get_texture = get_history(1)},
			{binding_index = 5, get_texture = get_history(2)},
			{
				binding_index = 6,
				get_texture = function()
					return post_source.GetExposureTexture()
				end,
			},
			{
				binding_index = 7,
				get_texture = function()
					return post_source.GetExposureTexture(true)
				end,
			},
		},
		uniform_buffers = {
			{
				name = "afterimage_data",
				binding_index = 10,
				block = {
					render3d.camera_block,
					render3d.prev_camera_block,
					{"dt", "float"},
					{"history_valid", "int"},
					{"depth_tex", "int"},
					{"velocity_tex", "int"},
					{"time_scale", "float"},
					{"adaptation_ratio", "float"},
					{"falloff", "float"},
					{"persistence_seconds", "float"},
				},
				write = function(self, block)
					local frame = system.GetFrameNumber()
					local size = render.GetRenderImageSize()
					render3d.WriteCameraBlock(self, block)
					render3d.WritePreviousCameraBlock(self, block)
					block.dt = math.clamp(system.GetFrameTime(), 0, 0.1)
					block.history_valid = last_frame == frame - 1 and
						last_width == size.x and
						last_height == size.y and
						1 or
						0
					block.time_scale = exposure_model.Get("eye.afterimage_time_scale")
					block.adaptation_ratio = exposure_model.Get("eye.afterimage_adaptation_ratio")
					block.falloff = exposure_model.Get("eye.afterimage_falloff")
					block.persistence_seconds = exposure_model.Get("eye.afterimage_source_seconds")
					block.depth_tex = self:GetTextureIndex(gbuffer_layout.GetDepthTexture())
					block.velocity_tex = render3d.velocity_enabled:Get() and
						self:GetTextureIndex(gbuffer_layout.GetTexture("velocity")) or
						-1
					last_frame, last_width, last_height = frame, size.x, size.y
					return block
				end,
			},
		},
		shader = [[
			layout(set = 0, binding = 0, rgba16f) uniform writeonly image2D out_excitation;
			layout(set = 0, binding = 1, rgba16f) uniform writeonly image2D out_bleach;
			layout(set = 0, binding = 2) uniform sampler2D scene_tex;
			layout(set = 0, binding = 3) uniform sampler2D glare_tex;
			layout(set = 0, binding = 4) uniform sampler2D history_excitation_tex;
			layout(set = 0, binding = 5) uniform sampler2D history_bleach_tex;
			layout(set = 0, binding = 6) uniform sampler2D exposure_tex;
			layout(set = 0, binding = 7) uniform sampler2D prev_exposure_tex;
			layout(set = 0, binding = 8, rgba16f) uniform writeonly image2D out_source;
			layout(set = 0, binding = 9) uniform sampler2D history_source_tex;
			const float HALF_SOURCE_LUMINANCE = ]] .. string.format("%.3f", HALF_SOURCE_LUMINANCE) .. [[;
			const float CYCLE_SECONDS = ]] .. string.format("%.3f", CYCLE_SECONDS) .. [[;
			const float HALF_BLEACH_LUMINANCE = ]] .. string.format("%.3f", HALF_BLEACH_LUMINANCE) .. [[;
			const float RECOVERY_SECONDS = ]] .. string.format("%.3f", RECOVERY_SECONDS) .. [[;
			const int MAX_PATH_STEPS = ]] .. MAX_PATH_STEPS .. [[;
			const float MAX_MOTION = ]] .. string.format("%.3f", MAX_MOTION) .. [[;
		]] .. post_source.GetPreExposureFromExposureGLSL() .. compute_helpers.GetScreenHelpersGLSL() .. afterimage.GetApplyGLSL() .. screen_reconstruct.GetViewRayFromUVGLSL("afterimage_data") .. [[
			vec3 fetch_retinal(vec2 at, float exposure, float pre_exposure) {
				return max(texture(scene_tex, edge_clamp_uv(at, textureSize(scene_tex, 0))).rgb + texture(glare_tex, edge_clamp_uv(at, textureSize(glare_tex, 0))).rgb / exposure, vec3(0.0)) / pre_exposure;
			}

			void add_stimulus(vec3 retinal, float weight, float half_source, inout vec3 brightest, inout vec3 source, inout float source_level) {
				vec3 cones = RGB_TO_CONES * retinal;
				float lum = luminance(retinal);
				float level = lum * lum / (lum * lum + half_source * half_source) * weight;
				brightest = max(brightest, cones * weight);
				source = max(source, cones / max(max(cones.x, max(cones.y, cones.z)), 1e-6) * level);
				source_level = max(source_level, level);
			}

			void main() {
				ivec2 pos = get_screen_pos();
				ivec2 size = imageSize(out_excitation);

				if (!is_screen_pos_in_bounds(pos, size)) return;

				vec2 uv = get_screen_uv(pos, size);
				float pre_exposure = pre_exposure_from_exposure(texture(prev_exposure_tex, vec2(0.5)).r);
				float exposure = texture(exposure_tex, vec2(0.5)).r / pre_exposure;
				float adapting_luminance = exp2(texture(exposure_tex, vec2(0.5)).b - 3.0);
				float half_bleach = max(HALF_BLEACH_LUMINANCE, afterimage_data.adaptation_ratio * adapting_luminance);
				float half_source = max(HALF_SOURCE_LUMINANCE, afterimage_data.adaptation_ratio * adapting_luminance);
				float depth = texelFetch(TEXTURE(afterimage_data.depth_tex), ivec2(uv * vec2(textureSize(TEXTURE(afterimage_data.depth_tex), 0))), 0).r;
				vec2 motion = vec2(0.0);

				if (afterimage_data.velocity_tex != -1 && depth > 0.0) {
					motion = texelFetch(TEXTURE(afterimage_data.velocity_tex), ivec2(uv * vec2(textureSize(TEXTURE(afterimage_data.velocity_tex), 0))), 0).xy;
				} else {
					vec4 previous_clip = afterimage_data.prev_projection * mat4(mat3(afterimage_data.prev_view)) * vec4(get_view_ray(uv), 1.0);

					if (previous_clip.w > 0.0) motion = uv - (previous_clip.xy / previous_clip.w * 0.5 + 0.5);
				}

				if (length(motion) > MAX_MOTION) motion = vec2(0.0);

				int steps = int(clamp(ceil(length(motion * vec2(size))), 1.0, float(MAX_PATH_STEPS)));
				vec3 brightest = vec3(0.0);
				vec3 source = vec3(0.0);
				float source_level = 0.0;

				for (int i = 0; i < steps; i++) {
					vec2 at = uv + motion * (steps > 1 ? float(i) / float(steps - 1) : 0.0);
					if (any(lessThan(at, vec2(0.0))) || any(greaterThan(at, vec2(1.0)))) continue;

					add_stimulus(fetch_retinal(at, exposure, pre_exposure), 1.0, half_source, brightest, source, source_level);
				}

				bool valid = afterimage_data.history_valid != 0;
				float excitation = valid ? texelFetch(history_excitation_tex, pos, 0).r : 0.0;
				vec3 bleach = valid ? texelFetch(history_bleach_tex, pos, 0).rgb : vec3(0.0);
				vec4 source_state = valid ? texelFetch(history_source_tex, pos, 0) : vec4(0.0);
				float cycle_rate = pow(clamp(excitation, 1e-3, 1.0), afterimage_data.falloff) / (CYCLE_SECONDS * afterimage_data.time_scale) * (1.0 - clamp(source_state.a, 0.0, 1.0));
				excitation = max(excitation * exp(-afterimage_data.dt * cycle_rate), source_level);
				float source_rate = pow(clamp(source_state.a, 1e-3, 1.0), afterimage_data.falloff) / afterimage_data.persistence_seconds;
				source_state = vec4(max(source_state.rgb * exp(-afterimage_data.dt * source_rate), source), max(source_state.a * exp(-afterimage_data.dt * source_rate), source_level));
				vec3 rate = brightest / half_bleach;
				bleach = (bleach + afterimage_data.dt * rate) / (1.0 + afterimage_data.dt * (rate + 1.0 / (RECOVERY_SECONDS * afterimage_data.time_scale)));
				imageStore(out_excitation, pos, vec4(vec3(excitation), 1.0));
				imageStore(out_bleach, pos, vec4(clamp(bleach, vec3(0.0), vec3(1.0)), 1.0));
				imageStore(out_source, pos, source_state);
			}
		]],
	},
	{
		name = "afterimage_blur",
		is_enabled = afterimage.IsEnabled,
		ComputePass = true,
		ColorFormat = {
			{"r16g16b16a16_sfloat", {"afterimage_blurred", "rgba"}},
			{"r16g16b16a16_sfloat", {"afterimage_bleach_blurred", "rgba"}},
			{"r16g16b16a16_sfloat", {"afterimage_source_blurred", "rgba"}},
		},
		framebuffer_count = 1,
		scale = 0.125,
		LocalSize = COMPUTE_LOCAL_SIZE,
		storage_images = {
			{binding_index = 0, attachment = 1, dst_stage = "compute"},
			{binding_index = 1, attachment = 2, dst_stage = "compute"},
			{binding_index = 4, attachment = 3, dst_stage = "compute"},
		},
		sampled_images = {
			{binding_index = 2, get_texture = get_current(1)},
			{binding_index = 3, get_texture = get_current(2)},
			{binding_index = 5, get_texture = get_current(3)},
		},
		block = {{"unused", "int"}},
		write = function(self, block)
			return block
		end,
		shader = [[
			layout(set = 0, binding = 0, rgba16f) uniform writeonly image2D out_excitation;
			layout(set = 0, binding = 1, rgba16f) uniform writeonly image2D out_bleach;
			layout(set = 0, binding = 2) uniform sampler2D excitation_tex;
			layout(set = 0, binding = 3) uniform sampler2D bleach_tex;
			layout(set = 0, binding = 4, rgba16f) uniform writeonly image2D out_source;
			layout(set = 0, binding = 5) uniform sampler2D source_tex;
		]] .. compute_helpers.GetScreenHelpersGLSL() .. [[
			void main() {
				ivec2 pos = get_screen_pos();
				ivec2 size = imageSize(out_excitation);

				if (!is_screen_pos_in_bounds(pos, size)) return;

				vec2 uv = get_screen_uv(pos, size);
				vec3 excitation = vec3(0.0);
				vec3 bleach = vec3(0.0);
				vec4 source = vec4(0.0);

				for (int y = -1; y <= 1; y++) {
					for (int x = -1; x <= 1; x++) {
						float weight = float((2 - abs(x)) * (2 - abs(y))) / 16.0;
						vec2 at = edge_clamp_uv(uv + vec2(x, y) * ]] .. string.format("%.3f", BLUR_SPACING) .. [[ / vec2(size), size);
						excitation += texture(excitation_tex, at).rgb * weight;
						bleach += texture(bleach_tex, at).rgb * weight;
						source += texture(source_tex, at) * weight;
					}
				}

				imageStore(out_excitation, pos, vec4(excitation, 1.0));
				imageStore(out_bleach, pos, vec4(bleach, 1.0));
				imageStore(out_source, pos, source);
			}
		]],
	},
}

function afterimage.GetTexture(attachment)
	if not afterimage.IsEnabled() then return nil end

	local pipeline = render3d.pipelines.afterimage_blur

	if not pipeline or not pipeline.framebuffers then return nil end

	return pipeline:GetFramebuffer():GetAttachment(attachment)
end

return afterimage
