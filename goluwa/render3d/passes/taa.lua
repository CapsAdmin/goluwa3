local Vec2 = import("goluwa/structs/vec2.lua")
local system = import("goluwa/system.lua")
local render = import("goluwa/render/render.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local gbuffer_layout = import("goluwa/render3d/gbuffer_layout.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local screen_reconstruct = import("goluwa/render3d/screen_reconstruct.lua")
local rcas = import("goluwa/render3d/rcas.lua")
local halton

do
	function halton(i, base)
		local f, r = 1, 0

		while i > 0 do
			f = f / base
			r = r + f * (i % base)
			i = math.floor(i / base)
		end

		return r
	end
end

local ZERO = Vec2(0, 0)

local function get_jitter_phase_count(input, viewport)
	return math.ceil(8 * (viewport.w / input.x) ^ 2)
end

local frame_state = {
	history_valid = 0,
	last_frame = -1,
	last_width = 0,
	last_height = 0,
	last_input_width = 0,
	last_input_height = 0,
}
local EXPOSURE_GLSL = "float get_compress_exposure(int pre_exposure_tex) { return pre_exposure_tex != -1 ? " .. string.format("%.1f", post_source.PRE_EXPOSURE_HEADROOM) .. " : 1.0; }"

local function is_enabled()
	return render3d.IsAntiAliasingEnabled("taa")
end

local function attachment(name, previous, index)
	local frame = system.GetFrameNumber()
	return render3d.pipelines[name]:GetFramebuffer((previous and frame + 1 or frame) % 2 + 1):GetAttachment(index)
end

local function write_jitter_delta(block)
	local camera = render3d.GetCamera()
	local jitter = camera:GetJitter()
	local viewport = camera:GetViewport()
	block.jitter_delta[0] = (render3d.previous_jitter.x - jitter.x) / viewport.w
	block.jitter_delta[1] = (render3d.previous_jitter.y - jitter.y) / viewport.h
end

local REPROJECT_GLSL = [[
	const float FP16_MIN = 6.10e-05;
	const float FP16_MAX = 65504.0;

	bool is_uv_inside(vec2 uv) {
		return all(greaterThanEqual(uv, vec2(0.0))) && all(lessThanEqual(uv, vec2(1.0)));
	}

	float min_divided_by_max(float a, float b) {
		float m = max(a, b);
		return m > 0.0 ? min(a, b) / m : 0.0;
	}
]]
return {
	{
		name = "taa_inputs",
		resolution = "internal",
		is_enabled = is_enabled,
		ColorFormat = {
			{"r16g16b16a16_sfloat", {"inputs", "rgba"}},
			{"r16_sfloat", {"view_depth", "r"}},
			{"r16g16_sfloat", {"translucency", "rg"}},
		},
		framebuffer_count = 2,
		pre_render = function()
			local camera = render3d.GetMainCamera()
			render3d.previous_jitter = camera:GetJitter():Copy()

			if not render3d.IsJitteredAntiAliasingEnabled() then
				camera:SetJitter(ZERO)
				return
			end

			local input = render3d.GetRenderSize()
			local viewport = camera:GetViewport()
			local i = system.GetFrameNumber() % get_jitter_phase_count(input, viewport) + 1
			camera:SetJitter(
				Vec2(
					(halton(i, 2) - 0.5) * viewport.w / input.x,
					(halton(i, 3) - 0.5) * viewport.h / input.y
				)
			)
		end,
		fragment = {
			uniform_buffers = {
				{
					name = "inputs_data",
					binding_index = 2,
					block = {
						render3d.camera_block,
						render3d.prev_camera_block,
						{"source_tex", "int"},
						{"water_distance_tex", "int"},
						{"depth_tex", "int"},
						{"velocity_tex", "int"},
						{"translucent_motion_tex", "int"},
						{"translucent_additive_tex", "int"},
						post_source.pre_exposure_block,
					},
					write = function(self, block)
						render3d.WriteCameraBlock(self, block)
						render3d.WritePreviousCameraBlock(self, block)
						local frame = system.GetFrameNumber()
						block.source_tex = self:GetTextureIndex(post_source.GetSceneSourceTexture({name = "taa"}))
						block.water_distance_tex = (
								render3d.IsOceanEnabled() or
								render3d.IsWaterEnabled()
							) and
							render3d.IsPassEnabled("water") and
							render3d.pipelines.water.framebuffers and
							self:GetTextureIndex(render3d.pipelines.water:GetFramebuffer(frame % 2 + 1):GetAttachment(2)) or
							-1
						block.depth_tex = self:GetTextureIndex(gbuffer_layout.GetDepthTexture())
						block.velocity_tex = render3d.velocity_enabled:Get() and
							self:GetTextureIndex(gbuffer_layout.GetTexture("velocity")) or
							-1
						block.translucent_motion_tex = render3d.IsPassEnabled("translucent") and
							self:GetTextureIndex(render3d.pipelines.translucent_accumulate:GetFramebuffer():GetAttachment(2)) or
							-1
						block.translucent_additive_tex = render3d.IsPassEnabled("translucent") and
							self:GetTextureIndex(render3d.pipelines.translucent_accumulate:GetFramebuffer():GetAttachment(3)) or
							-1
						post_source.WritePreExposureBlock(self, block)
						local size = render.GetRenderImageSize()
						local input = render3d.GetRenderSize()
						local state = frame_state
						state.history_valid = (
								not render3d.IsCameraCut() and
								state.last_frame == frame - 1 and
								state.last_width == size.x and
								state.last_height == size.y and
								state.last_input_width == input.x and
								state.last_input_height == input.y
							)
							and
							1 or
							0
						state.last_frame = frame
						state.last_width, state.last_height = size.x, size.y
						state.last_input_width, state.last_input_height = input.x, input.y
						return block
					end,
				},
			},
			shader = REPROJECT_GLSL .. post_source.GetCompressGLSL() .. post_source.GetPreExposureGLSL("inputs_data") .. EXPOSURE_GLSL .. screen_reconstruct.GetViewRayFromUVGLSL("inputs_data") .. screen_reconstruct.GetViewDepthGLSL("inputs_data") .. screen_reconstruct.GetViewPosGLSL("inputs_data") .. [[
			void main() {
				ivec2 size = textureSize(TEXTURE(inputs_data.depth_tex), 0);
				ivec2 pixel = ivec2(gl_FragCoord.xy);
				vec2 uv = (vec2(pixel) + 0.5) / vec2(size);
				float depth = texelFetch(TEXTURE(inputs_data.depth_tex), pixel, 0).r;
				float closest_depth = 0.0;
				ivec2 closest_pixel = pixel;

				for (int y = -1; y <= 1; y++) {
					for (int x = -1; x <= 1; x++) {
						ivec2 p = clamp(pixel + ivec2(x, y), ivec2(0), size - 1);
						float d = texelFetch(TEXTURE(inputs_data.depth_tex), p, 0).r;

						if (d > closest_depth) {
							closest_depth = d;
							closest_pixel = p;
						}
					}
				}

				vec2 closest_uv = (vec2(closest_pixel) + 0.5) / vec2(size);
				vec2 motion;
				float expected_depth = -1.0;

				if (closest_depth > 0.0 && inputs_data.velocity_tex != -1) {
					motion = texelFetch(TEXTURE(inputs_data.velocity_tex), closest_pixel, 0).xy;
					expected_depth = depth > 0.0 ? texelFetch(TEXTURE(inputs_data.velocity_tex), pixel, 0).z : -1.0;
				} else {
					vec4 world_pos = inputs_data.inv_view * vec4(get_view_pos(closest_uv, closest_depth), 1.0);
					vec4 prev_clip = inputs_data.prev_projection * inputs_data.prev_view * vec4(world_pos.xyz, 1.0);
					motion = closest_uv - (prev_clip.xy / prev_clip.w * 0.5 + 0.5);
				}

				float water_distance = inputs_data.water_distance_tex != -1 ? texelFetch(TEXTURE(inputs_data.water_distance_tex), pixel, 0).r : -1.0;

				if (water_distance > 0.0) {
					vec4 water_clip = inputs_data.prev_projection * inputs_data.prev_view * vec4(inputs_data.camera_position + get_view_ray(uv) * water_distance, 1.0);
					motion = uv - (water_clip.xy / water_clip.w * 0.5 + 0.5);
					expected_depth = -1.0;
				}

				float reactive = 0.0;
				float transparency = 0.0;

				if (inputs_data.translucent_motion_tex != -1) {
					vec4 translucent = texelFetch(TEXTURE(inputs_data.translucent_motion_tex), pixel, 0);
					float coverage = min(translucent.b, 1.0);
					float emission = dot(texelFetch(TEXTURE(inputs_data.translucent_additive_tex), pixel, 0).rgb, vec3(1.0));
					reactive = max(smoothstep(0.0, 0.02, emission), 0.6 * smoothstep(0.0, 0.2, coverage));

					if (coverage > 0.0) {
						vec2 translucent_motion = translucent.rg / translucent.b;
						transparency = 2.0 * min(coverage, 1.0 - coverage) * smoothstep(0.5, 2.0, length((translucent_motion - motion) * vec2(size)));

						if (coverage > 0.5) {
							motion = translucent_motion;
							expected_depth = -1.0;
						}
					}
				}

				float exposure = get_compress_exposure(inputs_data.pre_exposure_tex);
				float luma = compress(max(texelFetch(TEXTURE(inputs_data.source_tex), pixel, 0).rgb, vec3(0.0)), exposure).x;
				set_inputs(vec4(motion, expected_depth, luma));
				set_view_depth(depth > 0.0 ? min(get_view_depth(uv, depth), FP16_MAX) : FP16_MAX);
				set_translucency(vec2(reactive, transparency));
			}
		]],
		},
		CullMode = "none",
		DepthTest = false,
		DepthWrite = false,
	},
	{
		name = "taa_reactivity",
		resolution = "internal",
		is_enabled = is_enabled,
		ColorFormat = {{"r16g16b16a16_sfloat", {"masks", "rgba"}}},
		fragment = {
			uniform_buffers = {
				{
					name = "reactivity_data",
					binding_index = 2,
					block = {
						{"jitter_delta", "vec2"},
						{"inputs_tex", "int"},
						{"view_depth_tex", "int"},
						{"translucency_tex", "int"},
						{"prev_inputs_tex", "int"},
						{"prev_view_depth_tex", "int"},
						{"history_valid", "int"},
					},
					write = function(self, block)
						write_jitter_delta(block)
						block.inputs_tex = self:GetTextureIndex(attachment("taa_inputs", false, 1))
						block.view_depth_tex = self:GetTextureIndex(attachment("taa_inputs", false, 2))
						block.translucency_tex = self:GetTextureIndex(attachment("taa_inputs", false, 3))
						block.prev_inputs_tex = self:GetTextureIndex(attachment("taa_inputs", true, 1))
						block.prev_view_depth_tex = self:GetTextureIndex(attachment("taa_inputs", true, 2))
						block.history_valid = frame_state.history_valid
						return block
					end,
				},
			},
			shader = REPROJECT_GLSL .. [[
			const ivec2 CROSS[5] = ivec2[5](ivec2(0, 0), ivec2(-1, 0), ivec2(1, 0), ivec2(0, -1), ivec2(0, 1));

			ivec2 size;

			void sort5(inout float s[5]) {
				float t;
				#define SWAP(i, j) t = min(s[i], s[j]); s[j] = max(s[i], s[j]); s[i] = t;
				SWAP(0, 3) SWAP(1, 4) SWAP(0, 2) SWAP(1, 3) SWAP(0, 1) SWAP(2, 4) SWAP(1, 2) SWAP(3, 4) SWAP(2, 3)
				#undef SWAP
			}

			float minimum_difference(float a_set[5], float b_set[5]) {
				sort5(a_set);
				sort5(b_set);
				float min_diff = FP16_MAX - 1.0;

				if (min(a_set[4], b_set[4]) <= 1.175494351e-38) return 0.0;

				int a = 0;
				int b = 0;

				for (int i = 0; i < 5 && min_diff < FP16_MAX; i++) {
					float diff = a_set[a] - b_set[b];

					if (abs(diff) > FP16_MIN) {
						diff = sign(diff) * (1.0 - min_divided_by_max(a_set[a], b_set[b]));
						min_diff = abs(diff) < abs(min_diff) ? diff : min_diff;
						a = min(a + int(a_set[a] < b_set[b]), 4);
						b = min(b + int(a_set[a] >= b_set[b]), 4);
					} else {
						min_diff = FP16_MAX;
					}
				}

				return min_diff * float(min_diff < FP16_MAX - 1.0);
			}

			void main() {
				size = textureSize(TEXTURE(reactivity_data.inputs_tex), 0);
				ivec2 pixel = ivec2(gl_FragCoord.xy);
				vec2 uv = (vec2(pixel) + 0.5) / vec2(size);
				vec4 inputs = texelFetch(TEXTURE(reactivity_data.inputs_tex), pixel, 0);
				vec2 motion = inputs.xy;
				float expected_depth = inputs.z;
				vec2 prev_uv = uv - motion + reactivity_data.jitter_delta;
				bool inside = reactivity_data.history_valid != 0 && is_uv_inside(prev_uv);
				float disocclusion = 0.0;
				float shading_difference = 0.0;

				if (inside) {
					if (expected_depth > 0.0) {
						vec4 previous = textureGather(TEXTURE(reactivity_data.prev_view_depth_tex), prev_uv, 0);
						disocclusion = smoothstep(0.02, 0.1, (expected_depth - max(max(previous.x, previous.y), max(previous.z, previous.w))) / expected_depth);
					}

					ivec2 prev_base = ivec2(floor(prev_uv * vec2(size)));
					float current_set[5];
					float previous_set[5];

					for (int i = 0; i < 5; i++) {
						current_set[i] = max(texelFetch(TEXTURE(reactivity_data.inputs_tex), clamp(pixel + CROSS[i], ivec2(0), size - 1), 0).w, FP16_MIN);
						previous_set[i] = max(texelFetch(TEXTURE(reactivity_data.prev_inputs_tex), clamp(prev_base + CROSS[i], ivec2(0), size - 1), 0).w, FP16_MIN);
					}

					shading_difference = minimum_difference(current_set, previous_set);
				}

				ivec2 reprojected_pixel = clamp(ivec2((uv - motion) * vec2(size)), ivec2(0), size - 1);
				float velocity_4k = length(motion * vec2(3840.0, 2160.0));
				float reprojected_velocity_4k = length(texelFetch(TEXTURE(reactivity_data.inputs_tex), reprojected_pixel, 0).xy * vec2(3840.0, 2160.0));
				float divergence = velocity_4k > 0.0 ?
					(1.0 - clamp(reprojected_velocity_4k / velocity_4k, 0.0, 1.0)) *
					min_divided_by_max(texelFetch(TEXTURE(reactivity_data.view_depth_tex), reprojected_pixel, 0).r, texelFetch(TEXTURE(reactivity_data.view_depth_tex), pixel, 0).r) *
					clamp(velocity_4k / 10.0, 0.0, 1.0) :
					0.0;
				float reactive_input = 0.0;

				for (int y = -1; y <= 1; y++) {
					for (int x = -1; x <= 1; x++) {
						reactive_input = max(reactive_input, texelFetch(TEXTURE(reactivity_data.translucency_tex), clamp(pixel + ivec2(x, y), ivec2(0), size - 1), 0).r);
					}
				}

				float transparency = texelFetch(TEXTURE(reactivity_data.translucency_tex), pixel, 0).g;
				set_masks(vec4(max(divergence, transparency), disocclusion, shading_difference, reactive_input));
			}
		]],
		},
		CullMode = "none",
		DepthTest = false,
		DepthWrite = false,
	},
	{
		name = "taa_shading",
		resolution = "internal",
		is_enabled = is_enabled,
		ColorFormat = {
			{"r16g16b16a16_sfloat", {"reactivity", "rgba"}},
			{"r16g16b16a16_sfloat", {"luma_history", "rgba"}},
		},
		framebuffer_count = 2,
		fragment = {
			uniform_buffers = {
				{
					name = "shading_data",
					binding_index = 2,
					block = {
						{"jitter_delta", "vec2"},
						{"masks_tex", "int"},
						{"inputs_tex", "int"},
						{"prev_luma_history_tex", "int"},
						{"history_valid", "int"},
					},
					write = function(self, block)
						write_jitter_delta(block)
						block.masks_tex = self:GetTextureIndex(render3d.pipelines.taa_reactivity:GetFramebuffer():GetAttachment(1))
						block.inputs_tex = self:GetTextureIndex(attachment("taa_inputs", false, 1))
						block.prev_luma_history_tex = self:GetTextureIndex(attachment("taa_shading", true, 2))
						block.history_valid = frame_state.history_valid
						return block
					end,
				},
			},
			shader = REPROJECT_GLSL .. [[
			void main() {
				ivec2 size = textureSize(TEXTURE(shading_data.masks_tex), 0);
				ivec2 pixel = ivec2(gl_FragCoord.xy);
				vec2 uv = (vec2(pixel) + 0.5) / vec2(size);
				vec4 masks = texelFetch(TEXTURE(shading_data.masks_tex), pixel, 0);
				float reactive = clamp(masks.x, 0.0, 1.0);
				float disocclusion = clamp(masks.y, 0.0, 1.0);
				float shading_change = 0.0;

				for (int level = 0; level < 3; level++) {
					int block = 1 << level;
					ivec2 base = (pixel / block) * block;
					float difference = 0.0;
					float sign_sum = 0.0;

					for (int y = 0; y < block; y++) {
						for (int x = 0; x < block; x++) {
							float d = texelFetch(TEXTURE(shading_data.masks_tex), min(base + ivec2(x, y), size - 1), 0).z;
							difference += d;
							sign_sum += d != 0.0 ? sign(d) : 0.0;
						}
					}

					float value = abs(difference * sign_sum) / float(block * block * block * block);

					if (value > 0.0) shading_change = max(shading_change, value);
				}

				shading_change = clamp(max(shading_change, masks.w), 0.0, 1.0);
				vec4 inputs = texelFetch(TEXTURE(shading_data.inputs_tex), pixel, 0);
				vec2 prev_uv = uv - inputs.xy + shading_data.jitter_delta;
				vec4 luma_history = vec4(0.0);
				float instability = 0.0;

				if (shading_data.history_valid != 0 && is_uv_inside(prev_uv) && disocclusion < 0.1 && shading_change < 0.1) {
					luma_history = textureLod(TEXTURE(shading_data.prev_luma_history_tex), prev_uv, 0.0);
					float luma = inputs.w;
					float diff0 = luma - luma_history.x;
					float similarity0 = min_divided_by_max(luma, luma_history.x);
					float max_similarity = similarity0;

					if (similarity0 < 1.0) {
						for (int i = 1; i < 4; i++) {
							if (sign(diff0) == sign(luma - luma_history[i])) max_similarity = max(max_similarity, min_divided_by_max(luma, luma_history[i]));
						}

						instability = float(max_similarity > similarity0);
					}

					luma_history = vec4(luma, luma_history.xyz);
					instability *= float(luma_history.w != 0.0);
					instability *= (1.0 - clamp(length(inputs.xy * vec2(3840.0, 2160.0)) / 20.0, 0.0, 1.0)) * (1.0 - disocclusion) * (1.0 - reactive) * (1.0 - shading_change);
				}

				set_reactivity(vec4(reactive, disocclusion, shading_change, instability));
				set_luma_history(luma_history);
			}
		]],
		},
		CullMode = "none",
		DepthTest = false,
		DepthWrite = false,
	},
	{
		name = "taa",
		is_enabled = is_enabled,
		ColorFormat = {
			{"r16g16b16a16_sfloat", {"color", "rgba"}},
			{"r16g16_sfloat", {"history_state", "rg"}},
			{"r16g16b16a16_sfloat", {"linear_color", "rgba"}},
		},
		framebuffer_count = 2,
		fragment = {
			uniform_buffers = {
				{
					name = "taa_data",
					binding_index = 2,
					block = {
						render3d.camera_block,
						{"jitter_phase_count", "float"},
						{"source_tex", "int"},
						{"history_tex", "int"},
						{"history_state_tex", "int"},
						{"linear_history_tex", "int"},
						{"inputs_tex", "int"},
						{"view_depth_tex", "int"},
						{"reactivity_tex", "int"},
						post_source.pre_exposure_block,
						{"history_valid", "int"},
					},
					write = function(self, block)
						render3d.WriteCameraBlock(self, block)
						block.jitter_phase_count = get_jitter_phase_count(render3d.GetRenderSize(), render3d.GetCamera():GetViewport())
						block.source_tex = self:GetTextureIndex(post_source.GetSceneSourceTexture({name = "taa"}))
						block.history_tex = self:GetTextureIndex(attachment("taa", true, 1))
						block.history_state_tex = self:GetTextureIndex(attachment("taa", true, 2))
						block.linear_history_tex = self:GetTextureIndex(attachment("taa", true, 3))
						block.inputs_tex = self:GetTextureIndex(attachment("taa_inputs", false, 1))
						block.view_depth_tex = self:GetTextureIndex(attachment("taa_inputs", false, 2))
						block.reactivity_tex = self:GetTextureIndex(attachment("taa_shading", false, 1))
						post_source.WritePreExposureBlock(self, block)
						block.history_valid = frame_state.history_valid
						return block
					end,
				},
			},
			shader = [[
]] .. post_source.GetCompressGLSL() .. post_source.GetPreExposureGLSL("taa_data") .. EXPOSURE_GLSL .. screen_reconstruct.GetViewDepthGLSL("taa_data") .. REPROJECT_GLSL .. [[
			const float AVERAGE_LANCZOS_WEIGHT_PER_FRAME = 0.74 / 16.0;
			const float ACCUMULATION_ADDED_PER_FRAME = 1.0 / 3.0;
			const float MIN_DISOCCLUSION_ACCUMULATION = -1.0 / 3.0;
			const float LOCK_THRESHOLD = 1.0;
			const float LOCK_MAX = 2.0;

			ivec2 input_size;
			float exposure;

			float load_luma(ivec2 p) {
				return compress(max(texelFetch(TEXTURE(taa_data.source_tex), clamp(p, ivec2(0), input_size - 1), 0).rgb, vec3(0.0)), exposure).x;
			}

			float thin_feature_confidence(ivec2 p) {
				float samples[9];
				const ivec2 offsets[9] = ivec2[9](ivec2(0, 0), ivec2(-1, -1), ivec2(0, -1), ivec2(1, -1), ivec2(-1, 0), ivec2(1, 0), ivec2(-1, 1), ivec2(0, 1), ivec2(1, 1));
				float luma_min = 3.402823466e+38;
				float luma_max = 1.175494351e-38;

				for (int i = 0; i < 9; i++) {
					samples[i] = load_luma(p + offsets[i]);
					luma_min = min(luma_min, samples[i]);
					luma_max = max(luma_max, samples[i]);
				}

				float dissimilar_min = 3.402823466e+38;
				float dissimilar_max = 0.0;
				uint pattern = 1u;

				for (int i = 1; i < 9; i++) {
					if (abs(samples[i] - samples[0]) / (luma_max - luma_min) < 0.9) {
						pattern |= 1u << uint(i);
					} else {
						dissimilar_min = min(dissimilar_min, samples[i]);
						dissimilar_max = max(dissimilar_max, samples[i]);
					}
				}

				if (!(samples[0] > dissimilar_max || samples[0] < dissimilar_min)) return 0.0;

				const uint rejection[4] = uint[4](0x17u, 0x2Du, 0xD1u, 0x1A1u);

				for (int i = 0; i < 4; i++) {
					if ((pattern & rejection[i]) == rejection[i]) return 0.0;
				}

				return 1.0 - luma_min / luma_max;
			}

			float lanczos2_approx_sq(float x2) {
				x2 = min(x2, 4.0);
				float a = (2.0 / 5.0) * x2 - 1.0;
				float b = (1.0 / 4.0) * x2 - 1.0;
				return ((25.0 / 16.0) * a * a - (25.0 / 16.0 - 1.0)) * (b * b);
			}

			vec2 clamp_uv(vec2 uv, vec2 size) {
				return clamp(uv, vec2(0.5) / size, vec2(1.0) - vec2(0.5) / size);
			}

			vec3 fetch_history(int history_tex, vec2 uv, float history_scale, bool compressed) {
				vec3 c = textureLod(TEXTURE(history_tex), uv, 0.0).rgb * history_scale;
				return compressed ? compress(c, exposure) : c;
			}

			vec3 sample_history(int history_tex, vec2 uv, vec2 size, float history_scale, bool compressed) {
				vec2 position = uv * size;
				vec2 center = floor(position - 0.5) + 0.5;
				vec2 f = position - center;
				vec2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
				vec2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
				vec2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
				vec2 w3 = f * f * (-0.5 + 0.5 * f);
				vec2 w12 = w1 + w2;
				vec2 tc0 = clamp_uv((center - 1.0) / size, size);
				vec2 tc3 = clamp_uv((center + 2.0) / size, size);
				vec2 tc12 = clamp_uv((center + w2 / w12) / size, size);
				vec3 tap_top = fetch_history(history_tex, vec2(tc12.x, tc0.y), history_scale, compressed);
				vec3 tap_left = fetch_history(history_tex, vec2(tc0.x, tc12.y), history_scale, compressed);
				vec3 tap_middle = fetch_history(history_tex, vec2(tc12.x, tc12.y), history_scale, compressed);
				vec3 tap_right = fetch_history(history_tex, vec2(tc3.x, tc12.y), history_scale, compressed);
				vec3 tap_bottom = fetch_history(history_tex, vec2(tc12.x, tc3.y), history_scale, compressed);
				vec4 result =
					vec4(tap_top, 1.0) * (w12.x * w0.y) +
					vec4(tap_left, 1.0) * (w0.x * w12.y) +
					vec4(tap_middle, 1.0) * (w12.x * w12.y) +
					vec4(tap_right, 1.0) * (w3.x * w12.y) +
					vec4(tap_bottom, 1.0) * (w12.x * w3.y);
				vec3 history = result.rgb / result.a;
				return clamp(history, min(min(min(tap_top, tap_left), min(tap_middle, tap_right)), tap_bottom), max(max(max(tap_top, tap_left), max(tap_middle, tap_right)), tap_bottom));
			}

			void main() {
				input_size = textureSize(TEXTURE(taa_data.source_tex), 0);
				vec2 output_size = vec2(textureSize(TEXTURE(taa_data.history_tex), 0));
				ivec2 pixel = ivec2(gl_FragCoord.xy);
				vec2 hr_uv = (vec2(pixel) + 0.5) / output_size;
				exposure = get_compress_exposure(taa_data.pre_exposure_tex);

				ivec2 nucleus = clamp(ivec2(hr_uv * vec2(input_size)), ivec2(0), input_size - 1);
				vec2 motion = texelFetch(TEXTURE(taa_data.inputs_tex), nucleus, 0).xy;
				float view_depth = texelFetch(TEXTURE(taa_data.view_depth_tex), nucleus, 0).r;
				vec2 lr_uv_jittered = hr_uv + taa_data.jitter / vec2(input_size);
				vec4 reactivity = clamp(textureLod(TEXTURE(taa_data.reactivity_tex), clamp_uv(lr_uv_jittered, vec2(input_size)), 0.0), 0.0, 1.0);
				float reactive = reactivity.x;
				float disocclusion = reactivity.y;
				float shading_change = reactivity.z;
				float luma_instability = reactivity.w;

				vec2 reprojected_uv = hr_uv - motion;
				bool existing_sample = taa_data.history_valid != 0 && is_uv_inside(reprojected_uv);
				float velocity_4k = length(motion * vec2(3840.0, 2160.0));

				vec2 history_state = existing_sample ? textureLod(TEXTURE(taa_data.history_state_tex), clamp_uv(reprojected_uv, output_size), 0.0).rg : vec2(0.0);
				float accumulation = clamp(history_state.x, 0.0, 1.0);
				accumulation = mix(accumulation, 0.0, shading_change);
				accumulation = mix(accumulation, min(MIN_DISOCCLUSION_ACCUMULATION, accumulation), disocclusion);
				accumulation *= float(round(accumulation * 100.0) > 1.0);
				float stored_accumulation = clamp(accumulation + ACCUMULATION_ADDED_PER_FRAME, 0.0, 1.0);
				bool initial_sample = accumulation == 0.0;

				float lock = history_state.y;
				float lock_decrease = max(shading_change, max(reactive, disocclusion));
				lock = max(0.0, lock - lock_decrease * LOCK_MAX);
				float lock_contribution = clamp(clamp(lock - LOCK_THRESHOLD, 0.0, 1.0) * (LOCK_MAX - LOCK_THRESHOLD), 0.0, 1.0);
				vec2 lr_scale = vec2(input_size) / output_size;
				ivec2 landing = ivec2(ceil(vec2(pixel) * lr_scale + taa_data.jitter - 0.5));

				if (all(lessThan(vec2(landing) + 0.5 - taa_data.jitter, (vec2(pixel) + 1.0) * lr_scale)) && all(greaterThanEqual(landing, ivec2(0))) && all(lessThan(landing, input_size))) {
					float new_lock = thin_feature_confidence(landing) * (1.0 - reactive);

					if (new_lock > 0.01) lock = min(lock + new_lock, LOCK_MAX);
				}

				lock = max(0.0, lock - 0.1 / taa_data.jitter_phase_count * (1.0 - lock_decrease));
				lock *= float(is_uv_inside(hr_uv + motion));

				vec3 history = vec3(0.0);
				vec3 linear_history = vec3(0.0);

				if (existing_sample && !initial_sample) {
					float history_scale = get_pre_exposure() / get_previous_pre_exposure();
					history = sample_history(taa_data.history_tex, reprojected_uv, output_size, history_scale, true);
					linear_history = sample_history(taa_data.linear_history_tex, reprojected_uv, output_size, history_scale, false);
				}

				float history_weight = min(accumulation, mix(accumulation, 0.15, clamp(velocity_4k / 0.5, 0.0, 1.0)));

				vec2 src_output_pos = (vec2(pixel) + 0.5) * vec2(input_size) / output_size;
				ivec2 src_input_pos = ivec2(floor(src_output_pos));
				vec2 src_unjittered_pos = vec2(src_input_pos) + 0.5 - taa_data.jitter;
				vec2 base_offset = src_unjittered_pos - src_output_pos;
				bvec2 flip = greaterThan(src_unjittered_pos, src_output_pos);
				ivec2 offset_tl = ivec2(flip.x ? -2 : -1, flip.y ? -2 : -1);

				float kernel_bias_max = min(1.99, output_size.x / float(input_size.x));
				float kernel_bias_min = max(1.0, (1.0 + kernel_bias_max) * 0.3);
				float kernel_bias_weight = min(1.0 - disocclusion * 0.5, min(1.0 - shading_change, clamp(history_weight * 5.0, 0.0, 1.0)));
				float kernel_bias = mix(kernel_bias_min, kernel_bias_max, kernel_bias_weight);

				vec3 upsampled = vec3(0.0);
				float upsampled_weight = 0.0;
				vec3 box_center = vec3(0.0);
				vec3 linear_center = vec3(0.0);
				vec3 box_vec = vec3(0.0);
				vec3 aabb_min = vec3(1e9);
				vec3 aabb_max = vec3(-1e9);
				float box_weight = 0.0;
				float farthest_view_depth = 0.0;

				for (int row = 0; row < 3; row++) {
					for (int col = 0; col < 3; col++) {
						ivec2 col_row = ivec2(flip.x ? 3 - col : col, flip.y ? 3 - row : row);
						vec2 sample_offset = base_offset + vec2(offset_tl + col_row);
						ivec2 sample_pos = src_input_pos + offset_tl + col_row;
						ivec2 clamped_pos = clamp(sample_pos, ivec2(0), input_size - 1);
						float on_screen = float(all(greaterThanEqual(sample_pos, ivec2(0))) && all(lessThan(sample_pos, input_size)));
						vec3 linear = max(texelFetch(TEXTURE(taa_data.source_tex), clamped_pos, 0).rgb, vec3(0.0));
						vec3 c = compress(linear, exposure);
						farthest_view_depth = max(farthest_view_depth, texelFetch(TEXTURE(taa_data.view_depth_tex), clamped_pos, 0).r);

						if (!initial_sample) {
							vec2 biased = sample_offset * kernel_bias;
							float w = on_screen * lanczos2_approx_sq(dot(biased, biased));
							upsampled += c * w;
							upsampled_weight += w;
						}

						float w = exp(-2.3 * dot(sample_offset, sample_offset)) * on_screen;
						box_center += c * w;
						linear_center += linear * w;
						box_vec += c * c * w;
						box_weight += w;
						aabb_min = min(aabb_min, c);
						aabb_max = max(aabb_max, c);
					}
				}

				box_weight = abs(box_weight) > 1.175494351e-38 ? box_weight : 1.0;
				box_center /= box_weight;
				linear_center /= box_weight;
				box_vec = sqrt(abs(box_vec / box_weight - box_center * box_center));

				upsampled_weight *= float(upsampled_weight > FP16_MIN);

				if (upsampled_weight > FP16_MIN) {
					upsampled = clamp(upsampled / upsampled_weight, aabb_min, aabb_max);
					upsampled_weight *= AVERAGE_LANCZOS_WEIGHT_PER_FRAME;
				}

				if (initial_sample) {
					upsampled = box_center;
					upsampled_weight = 1.0;
					history_weight = 0.0;
				}

				float linear_blend = AVERAGE_LANCZOS_WEIGHT_PER_FRAME / (history_weight + AVERAGE_LANCZOS_WEIGHT_PER_FRAME);

				float box_t = max(
					clamp(velocity_4k / 20.0, 0.0, 1.0),
					max(
						clamp(0.75 - farthest_view_depth / taa_data.view_scale / 20.0, 0.0, 1.0),
						max(1.0 - accumulation, max(sqrt(reactive), shading_change))
					)
				);
				vec3 scaled_box_vec = box_vec * vec3(1.7, 1.0, 1.0) * mix(3.0, 1.0, box_t);
				vec3 transformed_history = (history - box_center) / max(scaled_box_vec, vec3(1.193e-7));

				if (length(transformed_history) > 1.0) {
					vec3 clamped = normalize(transformed_history) * scaled_box_vec + box_center;
					float kept = clamp(max(luma_instability, lock_contribution) * accumulation * (1.0 - disocclusion), 0.0, 1.0);
					history = mix(clamped, history, kept);
					linear_blend = mix(linear_blend, 1.0, (1.0 - kept) * (1.0 - 1.0 / length(transformed_history)));
				}

				history_weight *= float(history_weight > FP16_MIN);
				history_weight = max(FP16_MIN, history_weight + upsampled_weight);
				vec3 result = mix(history, upsampled, clamp(upsampled_weight / history_weight, 0.0, 1.0));
				result.x = min(result.x, FP16_MAX * exposure / (1.0 + FP16_MAX * exposure));
				set_color(vec4(decompress(result, exposure), view_depth));
				set_history_state(vec2(stored_accumulation, lock));
				set_linear_color(vec4(min(mix(linear_history, linear_center, linear_blend), vec3(FP16_MAX)), 1.0));
			}
		]],
		},
		CullMode = "none",
		DepthTest = false,
		DepthWrite = false,
	},
	rcas.BuildPass{
		name = "taa_sharpen",
		is_enabled = is_enabled,
		get_source_texture = function()
			return attachment("taa", false, 1)
		end,
	},
}
