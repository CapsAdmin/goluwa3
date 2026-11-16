local Vec2 = import("goluwa/structs/vec2.lua")
local system = import("goluwa/system.lua")
local render = import("goluwa/render/render.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local gbuffer_layout = import("goluwa/render3d/gbuffer_layout.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local pvars = import("goluwa/cli/pvars.lua")
local screen_reconstruct = import("goluwa/render3d/screen_reconstruct.lua")
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

pvars.StartGroup("Post", "Anti-aliasing", {store = false, prefix = "taa_"})
local sharpness = pvars.Setup2{
	key = "r_taa_sharpen",
	default = 0.75,
	help = "the strength of the robust contrast adaptive sharpening (fsr's rcas) run on the taa output, which wins back what upscaling and the history resampling blur. 1 is the most rcas allows, 0 is off",
}
pvars.EndGroup()
local ZERO = Vec2(0, 0)

local function get_jitter_phase_count(input, viewport)
	return math.ceil(8 * (viewport.w / input.x) ^ 2)
end

local REQUIRED_TEXTURES = {"source_tex", "depth_tex", "history_tex", "history_state_tex"}
local last_frame = -1
local last_width, last_height = 0, 0
local last_input_width, last_input_height = 0, 0
local EXPOSURE_GLSL = "float get_compress_exposure(int pre_exposure_tex) { return pre_exposure_tex != -1 ? " .. string.format("%.1f", post_source.PRE_EXPOSURE_HEADROOM) .. " : 1.0; }"
return {
	{
		name = "taa",
		is_enabled = function()
			return render3d.IsAntiAliasingEnabled("taa")
		end,
		ColorFormat = {
			{"r16g16b16a16_sfloat", {"color", "rgba"}},
			{"r16g16_sfloat", {"history_state", "rg"}},
		},
		framebuffer_count = 2,
		pre_render = function()
			local camera = render3d.GetMainCamera()
			render3d.previous_jitter = camera:GetJitter():Copy()

			if not render3d.IsAntiAliasingEnabled("taa") then
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
					name = "taa_data",
					binding_index = 2,
					block = {
						render3d.camera_block,
						render3d.prev_camera_block,
						{"jitter", "vec2"},
						{"jitter_phase_count", "float"},
						{"source_tex", "int"},
						{"history_tex", "int"},
						{"history_state_tex", "int"},
						{"water_distance_tex", "int"},
						{"depth_tex", "int"},
						{"velocity_tex", "int"},
						{"translucent_motion_tex", "int"},
						{"translucent_additive_tex", "int"},
						post_source.pre_exposure_block,
						{"history_valid", "int"},
					},
					write = function(self, block)
						render3d.WriteCameraBlock(self, block)
						render3d.WritePreviousCameraBlock(self, block)
						local camera = render3d.GetCamera()
						local jitter = camera:GetJitter()
						local viewport = camera:GetViewport()
						local input = render3d.GetRenderSize()
						block.jitter[0] = jitter.x * input.x / viewport.w
						block.jitter[1] = jitter.y * input.y / viewport.h
						block.jitter_phase_count = get_jitter_phase_count(input, viewport)
						local frame = system.GetFrameNumber()
						local history = render3d.pipelines.taa:GetFramebuffer((frame + 1) % 2 + 1)
						block.source_tex = self:GetTextureIndex(post_source.GetSceneSourceTexture({name = "taa"}))
						block.history_tex = self:GetTextureIndex(history:GetAttachment(1))
						block.history_state_tex = self:GetTextureIndex(history:GetAttachment(2))
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

						for _, key in ipairs(REQUIRED_TEXTURES) do
							if block[key] == -1 then error("taa has no " .. key) end
						end

						local size = render.GetRenderImageSize()
						block.history_valid = (
								not render3d.IsCameraCut() and
								last_frame == frame - 1 and
								last_width == size.x and
								last_height == size.y and
								last_input_width == input.x and
								last_input_height == input.y
							)
							and
							1 or
							0
						last_frame = frame
						last_width, last_height = size.x, size.y
						last_input_width, last_input_height = input.x, input.y
						return block
					end,
				},
			},
			shader = [[
]] .. post_source.GetCompressGLSL() .. post_source.GetPreExposureGLSL("taa_data") .. EXPOSURE_GLSL .. [[

]] .. screen_reconstruct.GetViewRayFromUVGLSL("taa_data") .. [[

]] .. screen_reconstruct.GetViewDepthGLSL("taa_data") .. screen_reconstruct.GetViewPosGLSL("taa_data") .. [[

			const float FP16_MIN = 6.10e-05;
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

			vec3 sample_history(vec2 uv, vec2 size) {
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
				vec4 result =
					vec4(textureLod(TEXTURE(taa_data.history_tex), vec2(tc12.x, tc0.y), 0.0).rgb, 1.0) * (w12.x * w0.y) +
					vec4(textureLod(TEXTURE(taa_data.history_tex), vec2(tc0.x, tc12.y), 0.0).rgb, 1.0) * (w0.x * w12.y) +
					vec4(textureLod(TEXTURE(taa_data.history_tex), vec2(tc12.x, tc12.y), 0.0).rgb, 1.0) * (w12.x * w12.y) +
					vec4(textureLod(TEXTURE(taa_data.history_tex), vec2(tc3.x, tc12.y), 0.0).rgb, 1.0) * (w3.x * w12.y) +
					vec4(textureLod(TEXTURE(taa_data.history_tex), vec2(tc12.x, tc3.y), 0.0).rgb, 1.0) * (w12.x * w3.y);
				return max(result.rgb / result.a, vec3(0.0));
			}

			void main() {
				input_size = textureSize(TEXTURE(taa_data.source_tex), 0);
				vec2 output_size = vec2(textureSize(TEXTURE(taa_data.history_tex), 0));
				ivec2 pixel = ivec2(gl_FragCoord.xy);
				vec2 hr_uv = (vec2(pixel) + 0.5) / output_size;
				exposure = get_compress_exposure(taa_data.pre_exposure_tex);

				ivec2 nucleus = clamp(ivec2(hr_uv * vec2(input_size)), ivec2(0), input_size - 1);
				float nucleus_depth = texelFetch(TEXTURE(taa_data.depth_tex), nucleus, 0).r;
				float closest_depth = 0.0;
				float farthest_depth = 1.0;
				ivec2 closest_pixel = nucleus;

				for (int y = -1; y <= 1; y++) {
					for (int x = -1; x <= 1; x++) {
						ivec2 p = clamp(nucleus + ivec2(x, y), ivec2(0), input_size - 1);
						float depth = texelFetch(TEXTURE(taa_data.depth_tex), p, 0).r;

						if (depth > closest_depth) {
							closest_depth = depth;
							closest_pixel = p;
						}

						farthest_depth = min(farthest_depth, depth);
					}
				}

				vec2 input_uv = (vec2(closest_pixel) + 0.5) / vec2(input_size);
				float view_depth = get_view_depth((vec2(nucleus) + 0.5) / vec2(input_size), nucleus_depth);
				vec2 motion;
				float expected_depth = -1.0;

				if (closest_depth > 0.0 && taa_data.velocity_tex != -1) {
					motion = texelFetch(TEXTURE(taa_data.velocity_tex), closest_pixel, 0).xy;
					expected_depth = nucleus_depth > 0.0 ? texelFetch(TEXTURE(taa_data.velocity_tex), nucleus, 0).z : -1.0;
				} else {
					vec4 world_pos = taa_data.inv_view * vec4(get_view_pos(input_uv, closest_depth), 1.0);
					vec4 prev_clip = taa_data.prev_projection * taa_data.prev_view * vec4(world_pos.xyz, 1.0);
					motion = input_uv - (prev_clip.xy / prev_clip.w * 0.5 + 0.5);
				}

				float water_distance = taa_data.water_distance_tex != -1 ? texelFetch(TEXTURE(taa_data.water_distance_tex), nucleus, 0).r : -1.0;
				vec2 nucleus_uv = (vec2(nucleus) + 0.5) / vec2(input_size);

				if (water_distance > 0.0) {
					vec4 water_clip = taa_data.prev_projection * taa_data.prev_view * vec4(taa_data.camera_position + get_view_ray(nucleus_uv) * water_distance, 1.0);
					motion = nucleus_uv - (water_clip.xy / water_clip.w * 0.5 + 0.5);
					expected_depth = -1.0;
				}

				float shading_change = 0.0;

				if (taa_data.translucent_motion_tex != -1) {
					vec4 translucent = texelFetch(TEXTURE(taa_data.translucent_motion_tex), nucleus, 0);
					float coverage = min(translucent.b, 1.0);
					float emission = dot(texelFetch(TEXTURE(taa_data.translucent_additive_tex), nucleus, 0).rgb, vec3(1.0));
					shading_change = max(smoothstep(0.0, 0.02, emission), 0.6 * smoothstep(0.0, 0.2, coverage));

					if (coverage > 0.0) {
						vec2 translucent_motion = translucent.rg / translucent.b;
						shading_change = max(shading_change, 2.0 * min(coverage, 1.0 - coverage) * smoothstep(0.5, 2.0, length((translucent_motion - motion) * vec2(input_size))));

						if (coverage > 0.5) {
							motion = translucent_motion;
							expected_depth = -1.0;
						}
					}
				}

				vec2 reprojected_uv = hr_uv - motion;
				bool existing_sample = taa_data.history_valid != 0 && all(greaterThanEqual(reprojected_uv, vec2(0.0))) && all(lessThanEqual(reprojected_uv, vec2(1.0)));
				float velocity_4k = length(motion * vec2(3840.0, 2160.0));

				float disocclusion = 0.0;

				if (existing_sample && expected_depth > 0.0) {
					vec2 footprint = 0.5 / vec2(input_size);
					vec4 farthest = max(
						max(
							textureGather(TEXTURE(taa_data.history_tex), clamp_uv(reprojected_uv + vec2(-footprint.x, -footprint.y), output_size), 3),
							textureGather(TEXTURE(taa_data.history_tex), clamp_uv(reprojected_uv + vec2(footprint.x, -footprint.y), output_size), 3)
						),
						max(
							textureGather(TEXTURE(taa_data.history_tex), clamp_uv(reprojected_uv + vec2(-footprint.x, footprint.y), output_size), 3),
							textureGather(TEXTURE(taa_data.history_tex), clamp_uv(reprojected_uv + vec2(footprint.x, footprint.y), output_size), 3)
						)
					);
					disocclusion = smoothstep(0.02, 0.1, (expected_depth - max(max(farthest.x, farthest.y), max(farthest.z, farthest.w))) / expected_depth);
				}

				vec2 history_state = existing_sample ? textureLod(TEXTURE(taa_data.history_state_tex), clamp_uv(reprojected_uv, output_size), 0.0).rg : vec2(0.0);
				float accumulation = clamp(history_state.x, 0.0, 1.0);
				accumulation = mix(accumulation, 0.0, shading_change);
				accumulation = mix(accumulation, min(MIN_DISOCCLUSION_ACCUMULATION, accumulation), disocclusion);
				accumulation *= float(round(accumulation * 100.0) > 1.0);
				float stored_accumulation = clamp(accumulation + ACCUMULATION_ADDED_PER_FRAME, 0.0, 1.0);
				bool initial_sample = accumulation == 0.0;

				float lock = history_state.y;
				float lock_decrease = max(shading_change, disocclusion);
				lock = max(0.0, lock - lock_decrease * LOCK_MAX);
				float lock_contribution = clamp(clamp(lock - LOCK_THRESHOLD, 0.0, 1.0) * (LOCK_MAX - LOCK_THRESHOLD), 0.0, 1.0);
				vec2 lr_scale = vec2(input_size) / output_size;
				ivec2 landing = ivec2(ceil(vec2(pixel) * lr_scale + taa_data.jitter - 0.5));

				if (all(lessThan(vec2(landing) + 0.5 - taa_data.jitter, (vec2(pixel) + 1.0) * lr_scale)) && all(greaterThanEqual(landing, ivec2(0))) && all(lessThan(landing, input_size))) {
					float new_lock = thin_feature_confidence(landing);

					if (new_lock > 0.01) lock = min(lock + new_lock, LOCK_MAX);
				}

				lock = max(0.0, lock - 0.1 / taa_data.jitter_phase_count * (1.0 - lock_decrease));
				vec2 next_uv = hr_uv + motion;
				lock *= float(all(greaterThanEqual(next_uv, vec2(0.0))) && all(lessThanEqual(next_uv, vec2(1.0))));

				vec3 history = vec3(0.0);

				if (existing_sample && !initial_sample) {
					float history_scale = get_pre_exposure() / get_previous_pre_exposure();
					history = compress(sample_history(reprojected_uv, output_size) * history_scale, exposure);
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
				vec3 box_vec = vec3(0.0);
				vec3 aabb_min = vec3(1e9);
				vec3 aabb_max = vec3(-1e9);
				float box_weight = 0.0;

				for (int row = 0; row < 3; row++) {
					for (int col = 0; col < 3; col++) {
						ivec2 col_row = ivec2(flip.x ? 3 - col : col, flip.y ? 3 - row : row);
						vec2 sample_offset = base_offset + vec2(offset_tl + col_row);
						ivec2 sample_pos = src_input_pos + offset_tl + col_row;
						float on_screen = float(all(greaterThanEqual(sample_pos, ivec2(0))) && all(lessThan(sample_pos, input_size)));
						vec3 c = compress(max(texelFetch(TEXTURE(taa_data.source_tex), clamp(sample_pos, ivec2(0), input_size - 1), 0).rgb, vec3(0.0)), exposure);

						if (!initial_sample) {
							vec2 biased = sample_offset * kernel_bias;
							float w = on_screen * lanczos2_approx_sq(dot(biased, biased));
							upsampled += c * w;
							upsampled_weight += w;
						}

						float w = exp(-2.3 * dot(sample_offset, sample_offset)) * on_screen;
						box_center += c * w;
						box_vec += c * c * w;
						box_weight += w;
						aabb_min = min(aabb_min, c);
						aabb_max = max(aabb_max, c);
					}
				}

				box_weight = abs(box_weight) > 1.175494351e-38 ? box_weight : 1.0;
				box_center /= box_weight;
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

				float farthest_meters = farthest_depth > 0.0 ? get_view_depth(hr_uv, farthest_depth) / taa_data.view_scale : 1e6;
				float box_t = max(
					clamp(velocity_4k / 20.0, 0.0, 1.0),
					max(
						clamp(0.75 - farthest_meters / 20.0, 0.0, 1.0),
						max(1.0 - accumulation, shading_change)
					)
				);
				vec3 scaled_box_vec = box_vec * vec3(1.7, 1.0, 1.0) * mix(3.0, 1.0, box_t);
				vec3 transformed_history = (history - box_center) / max(scaled_box_vec, vec3(1.193e-7));

				if (length(transformed_history) > 1.0) {
					vec3 clamped = normalize(transformed_history) * scaled_box_vec + box_center;
					history = mix(clamped, history, clamp(lock_contribution * accumulation * (1.0 - disocclusion), 0.0, 1.0));
				}

				history_weight *= float(history_weight > FP16_MIN);
				history_weight = max(FP16_MIN, history_weight + upsampled_weight);
				vec3 result = mix(history, upsampled, clamp(upsampled_weight / history_weight, 0.0, 1.0));
				set_color(vec4(decompress(result, exposure), view_depth));
				set_history_state(vec2(stored_accumulation, lock));
			}
		]],
		},
		CullMode = "none",
		DepthTest = false,
		DepthWrite = false,
	},
	{
		name = "taa_sharpen",
		is_enabled = function()
			return sharpness:Get() > 0 and render3d.IsAntiAliasingEnabled("taa")
		end,
		ColorFormat = {{"r16g16b16a16_sfloat", {"color", "rgba"}}},
		fragment = {
			uniform_buffers = {
				{
					name = "sharpen_data",
					binding_index = 2,
					block = {
						{"source_tex", "int"},
						{"sharpness", "float"},
						post_source.pre_exposure_block,
					},
					write = function(self, block)
						block.source_tex = self:GetTextureIndex(render3d.pipelines.taa:GetFramebuffer(system.GetFrameNumber() % 2 + 1):GetAttachment(1))
						block.sharpness = sharpness:Get()
						post_source.WritePreExposureBlock(self, block)
						return block
					end,
				},
			},
			shader = [[
]] .. post_source.GetPreExposureGLSL("sharpen_data") .. EXPOSURE_GLSL .. [[

			const float RCAS_LIMIT = 0.25 - 1.0 / 16.0;

			ivec2 size;
			float exposure;

			vec3 load(ivec2 p) {
				vec3 c = max(texelFetch(TEXTURE(sharpen_data.source_tex), clamp(p, ivec2(0), size - 1), 0).rgb * exposure, vec3(0.0));
				return c / (max(c.r, max(c.g, c.b)) + 1.0);
			}

			void main() {
				size = textureSize(TEXTURE(sharpen_data.source_tex), 0);
				exposure = get_compress_exposure(sharpen_data.pre_exposure_tex);
				ivec2 pixel = ivec2(gl_FragCoord.xy);
				vec4 center = texelFetch(TEXTURE(sharpen_data.source_tex), pixel, 0);
				vec3 b = load(pixel + ivec2(0, -1));
				vec3 d = load(pixel + ivec2(-1, 0));
				vec3 e = load(pixel);
				vec3 f = load(pixel + ivec2(1, 0));
				vec3 h = load(pixel + ivec2(0, 1));
				float b_l = b.b * 0.5 + (b.r * 0.5 + b.g);
				float d_l = d.b * 0.5 + (d.r * 0.5 + d.g);
				float e_l = e.b * 0.5 + (e.r * 0.5 + e.g);
				float f_l = f.b * 0.5 + (f.r * 0.5 + f.g);
				float h_l = h.b * 0.5 + (h.r * 0.5 + h.g);
				float noise = 0.25 * (b_l + d_l + f_l + h_l) - e_l;
				float luma_range = max(max(max(b_l, d_l), max(e_l, f_l)), h_l) - min(min(min(b_l, d_l), min(e_l, f_l)), h_l);
				noise = -0.5 * clamp(abs(noise) / max(luma_range, 1e-6), 0.0, 1.0) + 1.0;
				vec3 min4 = min(min(b, d), min(f, h));
				vec3 max4 = max(max(b, d), max(f, h));
				float lower_limiter = clamp(e_l / max(min(min(b_l, d_l), min(f_l, h_l)), 1e-6), 0.0, 1.0);
				vec3 hit_min = min4 / max(4.0 * max4, vec3(1e-6)) * lower_limiter;
				vec3 hit_max = (1.0 - max4) / min(4.0 * min4 - 4.0, vec3(-1e-6));
				vec3 lobe_rgb = max(-hit_min, hit_max);
				float lobe = max(-RCAS_LIMIT, min(max(lobe_rgb.r, max(lobe_rgb.g, lobe_rgb.b)), 0.0)) * sharpen_data.sharpness * noise;
				vec3 sharpened = (lobe * (b + d + f + h) + e) / (4.0 * lobe + 1.0);
				set_color(vec4(sharpened / max(1.0 - max(sharpened.r, max(sharpened.g, sharpened.b)), 1e-6) / exposure, center.a));
			}
		]],
		},
		CullMode = "none",
		DepthTest = false,
		DepthWrite = false,
	},
}
