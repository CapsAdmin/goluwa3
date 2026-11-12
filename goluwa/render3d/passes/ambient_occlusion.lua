local glsl_common = import("goluwa/render3d/glsl_common.lua")
local assets = import("goluwa/assets.lua")
local system = import("goluwa/system.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local ambient_occlusion = import("goluwa/render3d/ambient_occlusion.lua")
local gi = import("goluwa/render3d/gi.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local gbuffer_layout = import("goluwa/render3d/gbuffer_layout.lua")
local compute_helpers = import("goluwa/render3d/compute_helpers.lua")
local screen_reconstruct = import("goluwa/render3d/screen_reconstruct.lua")
local COMPUTE_LOCAL_SIZE = {x = 8, y = 8, z = 1}
local RAY_COUNT = 32
local SAMPLE_COUNT = ambient_occlusion.GetSamples()
local SAMPLE_SKEW = 3.5
local GOLDEN_ANGLE = math.pi * (3 - math.sqrt(5))
local SCALE = 0.5
local RATIO = math.floor(1 / SCALE + 0.5)
local BLUR_DISTANCE_SIGMA = 2
local BLUR_DEPTH_SIGMA = 0.02
local BLUR_NORMAL_POWER = 8
local RAY_DIRECTIONS = {}
local SAMPLE_INNER = {}
local SAMPLE_OUTER = {}
local SAMPLE_WEIGHT = {}

for i = 0, RAY_COUNT - 1 do
	local angle = i * GOLDEN_ANGLE
	local radius = math.sqrt((i + 0.5) / RAY_COUNT)
	RAY_DIRECTIONS[i + 1] = string.format(
		"vec3(%.7f, %.7f, %.7f)",
		math.cos(angle) * radius,
		math.sin(angle) * radius,
		math.sqrt(1 - radius * radius)
	)
end

for i = 0, SAMPLE_COUNT - 1 do
	local inner = (i / SAMPLE_COUNT) ^ (SAMPLE_SKEW * 0.5)
	local outer = ((i + 1) / SAMPLE_COUNT) ^ (SAMPLE_SKEW * 0.5)
	local angle = i * GOLDEN_ANGLE
	SAMPLE_INNER[i + 1] = string.format("vec2(%.7f, %.7f)", math.cos(angle) * inner, math.sin(angle) * inner)
	SAMPLE_OUTER[i + 1] = string.format("vec2(%.7f, %.7f)", math.cos(angle) * outer, math.sin(angle) * outer)
	SAMPLE_WEIGHT[i + 1] = string.format("%.7f", math.sqrt(outer * outer - inner * inner))
end

return {
	{
		name = "ambient_occlusion",
		ComputePass = true,
		ColorFormat = {
			{"r16g16b16a16_sfloat", {"bounce_ao", "rgba"}},
			{"r16g16b16a16_sfloat", {"bent_normal", "rgba"}},
		},
		framebuffer_count = 1,
		scale = SCALE,
		LocalSize = COMPUTE_LOCAL_SIZE,
		storage_images = {
			{
				binding_index = 0,
				attachment = 1,
				dst_stage = "compute",
			},
			{
				binding_index = 1,
				attachment = 2,
				dst_stage = "compute",
			},
		},
		uniform_buffers = {
			{
				name = "lighting_data",
				binding_index = 3,
				block = {
					render3d.camera_block,
					render3d.last_frame_block,
					post_source.pre_exposure_block,
					{"blue_noise_tex", "int"},
					{"frame", "int"},
					{"gi_enabled", "int"},
					{"gi_strength", "float"},
					{"ddgi_screen_tex", "int"},
					{"radius", "float"},
					{"screen_radius", "float"},
					{"backface_threshold", "float"},
					{"backface_boost", "float"},
					{"inverse_max_slope", "float"},
					gbuffer_layout.block,
				},
				write = function(self, block)
					render3d.WriteCameraBlock(self, block)
					render3d.WriteLastFrameBlock(self, block)
					post_source.WritePreExposureBlock(self, block)
					block.blue_noise_tex = self:GetTextureIndex(assets.GetTexture("textures/render/blue_noise.lua"))
					block.frame = system.GetFrameNumber() % 4096
					block.gi_enabled = ambient_occlusion.IsGIEnabled() and block.last_frame_tex ~= -1 and 1 or 0
					block.gi_strength = ambient_occlusion.GetGIStrength()
					local screen = gi.GetScreenTexture()
					block.ddgi_screen_tex = screen and self:GetTextureIndex(screen) or -1
					block.radius = ambient_occlusion.GetRadius()
					block.screen_radius = ambient_occlusion.GetScreenRadius()
					block.backface_threshold = ambient_occlusion.GetBackfaceThreshold()
					block.backface_boost = ambient_occlusion.GetBackfaceBoost()
					block.inverse_max_slope = 1 / ambient_occlusion.GetMaxSlopeCompensation()
					gbuffer_layout.WriteBlock(self, block)
					return block
				end,
			},
		},
		custom_declarations = [[
			layout(set = 0, binding = 0, rgba16f) uniform writeonly image2D out_color;
			layout(set = 0, binding = 1, rgba16f) uniform writeonly image2D out_bent_normal;
			]],
		shader = [[
			vec2 in_uv;

			const int RAY_COUNT = ]] .. RAY_COUNT .. [[;
			const int SAMPLE_COUNT = ]] .. SAMPLE_COUNT .. [[;
			const vec3 RAY_DIRECTIONS[RAY_COUNT] = vec3[RAY_COUNT](]] .. table.concat(RAY_DIRECTIONS, ", ") .. [[);
			const vec2 SAMPLE_INNER[SAMPLE_COUNT] = vec2[SAMPLE_COUNT](]] .. table.concat(SAMPLE_INNER, ", ") .. [[);
			const vec2 SAMPLE_OUTER[SAMPLE_COUNT] = vec2[SAMPLE_COUNT](]] .. table.concat(SAMPLE_OUTER, ", ") .. [[);
			const float SAMPLE_WEIGHT[SAMPLE_COUNT] = float[SAMPLE_COUNT](]] .. table.concat(SAMPLE_WEIGHT, ", ") .. [[);
			const float BELOW_HORIZON_WEIGHT = 0.25;
			const float BOUNCE_MAX_LUMINANCE = 30000.0;

			]] .. compute_helpers.GetScreenHelpersGLSL() .. glsl_common.GetBlueNoiseGLSL() .. gbuffer_layout.GetDecodeGLSL("lighting_data") .. post_source.GetPreExposureGLSL("lighting_data") .. [[
			]] .. screen_reconstruct.GetWorldPosGLSL("lighting_data") .. [[
			]] .. screen_reconstruct.GetWorldPosFromUVGLSL("lighting_data", {function_name = "get_world_pos_uv"}) .. [[

			void set_color(vec3 bounce, float ao, vec3 bent, float view_depth) {
				imageStore(out_color, get_screen_pos(), vec4(bounce, ao));
				imageStore(out_bent_normal, get_screen_pos(), vec4(bent, view_depth));
			}

]] .. screen_reconstruct.GetGeometricNormalGLSL("lighting_data", {world_pos_function = "get_world_pos_uv"}) .. [[

			vec3 rotate_between(vec3 v, vec3 from, vec3 to) {
				vec3 axis = cross(from, to);
				return v * dot(from, to) + cross(axis, v) + axis * (dot(axis, v) / (1.0 + dot(from, to)));
			}

			vec3 get_view_pos(vec2 uv, float depth) {
				vec4 v = lighting_data.inv_projection * vec4(uv * 2.0 - 1.0, depth, 1.0);
				return v.xyz / v.w;
			}

			void get_ambient_occlusion(vec2 uv, vec3 world_pos, vec3 N, out float ao, out vec3 bounce, out vec3 bent) {
				vec3 p = (lighting_data.view * vec4(world_pos, 1.0)).xyz;
				float linear_depth = -p.z;
				vec3 V = normalize(-p);
				vec3 view_normal = normalize(mat3(lighting_data.view) * N);
				vec3 view_up = mat3(lighting_data.view) * vec3(0.0, 1.0, 0.0);

				float probe_sky = 0.0;

				if (lighting_data.ddgi_screen_tex != -1) {
					vec2 probe_uv = lighting_data.velocity_tex == -1 ? uv : uv - texture(TEXTURE(lighting_data.velocity_tex), uv).xy;
					float visibility = texture(TEXTURE(lighting_data.ddgi_screen_tex), probe_uv).a;
					probe_sky = clamp(visibility / max(0.5 * (1.0 + N.y), 0.05), 0.0, 1.0);
				}

				float below_horizon_weight = BELOW_HORIZON_WEIGHT * (1.0 - probe_sky);

				ivec2 screen_size = textureSize(TEXTURE(lighting_data.depth_tex), 0);
				ivec2 pixel = ivec2(uv * vec2(screen_size));
				vec4 noise_texel = blue_noise_texel(TEXTURE(lighting_data.blue_noise_tex), pixel);
				vec2 noise = blue_noise_r2(noise_texel.rg, float(lighting_data.frame));
				vec2 noise_b = blue_noise_r2(noise_texel.ba, float(lighting_data.frame));
				float offset_dither = noise.x;
				float sample_angle = noise.y * 6.2831853;
				float tangent_angle = noise_b.x * 6.2831853;
				float flip = noise_b.y < 0.5 ? -1.0 : 1.0;

				float world_radius = lighting_data.radius * lighting_data.view_scale;
				float max_apparent = abs(lighting_data.inv_projection[1][1]) * lighting_data.screen_radius * 2.0;
				float clamped_radius = min(world_radius, linear_depth * max_apparent * inversesqrt(max_apparent * max_apparent + 1.0));
				float apparent_radius = clamped_radius * inversesqrt(linear_depth * linear_depth - clamped_radius * clamped_radius);
				float circle_radius = apparent_radius * linear_depth;

				float pixel_size = abs(lighting_data.inv_projection[0][0]) / (float(screen_size.x) / ]] .. RATIO .. [[.0) * 1.41421356 * linear_depth;
				vec3 center = p + view_normal * pixel_size;

				float basis_a = 1.0 / (1.0 + V.z);
				float basis_b = V.x * V.y * basis_a;
				vec3 circle_right = vec3(V.x * V.x * basis_a - 1.0, basis_b, V.x) * flip * circle_radius;
				vec3 circle_up = vec3(basis_b, V.y * V.y * basis_a - 1.0, V.y) * circle_radius;
				vec2 sample_rotation = vec2(cos(sample_angle), sin(sample_angle));

				float tangent_a = 1.0 / max(1.0 + view_normal.z, 1e-4);
				float tangent_b = view_normal.x * view_normal.y * tangent_a;
				vec3 tangent_0 = vec3(view_normal.x * view_normal.x * tangent_a - 1.0, tangent_b, view_normal.x);
				vec3 bitangent_0 = vec3(tangent_b, view_normal.y * view_normal.y * tangent_a - 1.0, view_normal.y);
				vec3 tangent = cos(tangent_angle) * tangent_0 + sin(tangent_angle) * bitangent_0;
				vec3 bitangent = cos(tangent_angle) * bitangent_0 - sin(tangent_angle) * tangent_0;

				float history_scale = get_pre_exposure() / get_previous_pre_exposure();
				float bounce_max = BOUNCE_MAX_LUMINANCE * get_pre_exposure();
				vec2 history_texel = 1.0 / vec2(screen_size);
				vec3 total_bounce = vec3(0.0);
				uint ray_bits = 0u;

				for (int i = 0; i < SAMPLE_COUNT; i++) {
					vec2 offset = mix(SAMPLE_INNER[i], SAMPLE_OUTER[i], offset_dither);
					vec2 rotated = vec2(
						sample_rotation.x * offset.x - sample_rotation.y * offset.y,
						sample_rotation.y * offset.x + sample_rotation.x * offset.y
					);
					vec4 clip = lighting_data.projection * vec4(center + circle_right * rotated.x + circle_up * rotated.y, 1.0);

					if (clip.w <= 0.0) continue;

					vec2 sample_uv = clip.xy / clip.w * 0.5 + 0.5;

					if (sample_uv.x < 0.0 || sample_uv.x > 1.0 || sample_uv.y < 0.0 || sample_uv.y > 1.0) continue;

					float sample_depth = gbuffer_depth(sample_uv);

					if (sample_depth == 0.0) continue;

					vec3 d_pos = get_view_pos(sample_uv, sample_depth) - center;
					float length_squared = dot(d_pos, d_pos);

					if (length_squared >= clamped_radius * clamped_radius || dot(d_pos, view_normal) <= 0.0) continue;

					float inverse_length = inversesqrt(length_squared);
					vec3 direction = d_pos * inverse_length;
					vec3 sample_normal = normalize(mat3(lighting_data.view) * gbuffer_normal(sample_uv));
					bool sample_thin = gbuffer_is_thin(sample_uv);
					float slope = inversesqrt(max(dot(sample_normal, V), lighting_data.inverse_max_slope));
					float occluder_radius = clamped_radius * SAMPLE_WEIGHT[i] * slope * inverse_length;
					float sample_dot = dot(sample_normal, direction);
					float facing = sample_thin ? 1.0 : clamp(-sample_dot, 0.0, 1.0);

					if (!sample_thin) {
						if (sample_dot < lighting_data.backface_threshold) {
							direction = normalize(direction - sample_normal * (occluder_radius / max(1.0 - occluder_radius * occluder_radius * 0.5, 1e-6)));
						} else {
							occluder_radius *= mix(1.0, slope, lighting_data.backface_boost);
						}
					}

					vec3 hemisphere_direction = vec3(dot(direction, tangent), dot(direction, bitangent), dot(direction, view_normal));
					float occluder_cos = max(0.0, 1.0 - occluder_radius * occluder_radius * 0.5);
					uint occluded = 0u;

					for (int k = 0; k < RAY_COUNT; k++) {
						if (dot(RAY_DIRECTIONS[k], hemisphere_direction) > occluder_cos) occluded |= 1u << uint(k);
					}

					uint fresh = occluded & ~ray_bits;

					if (lighting_data.gi_enabled != 0 && fresh != 0u) {
						vec2 history_uv = lighting_data.velocity_tex == -1 ? sample_uv : sample_uv - texture(TEXTURE(lighting_data.velocity_tex), sample_uv).xy;

						if (history_uv.x > 0.0 && history_uv.x < 1.0 && history_uv.y > 0.0 && history_uv.y < 1.0) {
							vec3 hit = (
								texture(TEXTURE(lighting_data.last_frame_tex), history_uv + history_texel * vec2(-1.5, -0.5)).rgb +
								texture(TEXTURE(lighting_data.last_frame_tex), history_uv + history_texel * vec2(0.5, -1.5)).rgb +
								texture(TEXTURE(lighting_data.last_frame_tex), history_uv + history_texel * vec2(1.5, 0.5)).rgb +
								texture(TEXTURE(lighting_data.last_frame_tex), history_uv + history_texel * vec2(-0.5, 1.5)).rgb
							) * (0.25 * history_scale);
							hit *= min(1.0, bounce_max / max(luminance(hit), 1e-6));
							total_bounce += hit * (float(bitCount(fresh)) / float(RAY_COUNT) * facing);
						}
					}

					ray_bits |= occluded;
				}

				float up_tangent = dot(tangent, view_up);
				float up_bitangent = dot(bitangent, view_up);
				float up_normal = dot(view_normal, view_up);
				float sky_open = 0.0;
				float sky_total = 0.0;
				vec3 bent_tangent = vec3(0.0);

				for (int k = 0; k < RAY_COUNT; k++) {
					vec3 ray = RAY_DIRECTIONS[k];
					float up = ray.x * up_tangent + ray.y * up_bitangent + ray.z * up_normal;
					float direction_weight = below_horizon_weight + (1.0 - below_horizon_weight) * clamp(up, 0.0, 1.0);
					bool covered = ((ray_bits >> uint(k)) & 1u) != 0u;
					sky_total += direction_weight;

					if (!covered) sky_open += direction_weight;

					bent_tangent += ray * (covered ? (up <= 0.0 ? 1.0 - below_horizon_weight : 0.0) : 1.0);
				}

				ao = clamp(sky_open / sky_total, 0.0, 1.0);
				bounce = total_bounce * lighting_data.gi_strength;
				vec3 open_bent = tangent * bent_tangent.x + bitangent * bent_tangent.y + view_normal * bent_tangent.z;
				float bent_length = length(open_bent);
				bent = bent_length > 1e-4 ? normalize(mat3(lighting_data.inv_view) * (open_bent / bent_length)) : N;
			}

			void main() {
				ivec2 pos = get_screen_pos();
				ivec2 size = imageSize(out_color);

				if (!is_screen_pos_in_bounds(pos, size)) return;

				ivec2 pixel = pos * ]] .. RATIO .. [[;
				in_uv = (vec2(pixel) + 0.5) / vec2(textureSize(TEXTURE(lighting_data.depth_tex), 0));
				float depth = gbuffer_depth(pixel);
				float alpha = gbuffer_alpha(pixel);

				if (depth == 0.0 || alpha == 0.0) {
					set_color(vec3(0.0), 1.0, vec3(0.0), 0.0);
					return;
				}

				vec3 world_pos = get_world_pos(depth);
				vec3 shading_normal = normalize(gbuffer_normal(pixel));
				vec3 N = shading_normal;
				bool thin = gbuffer_is_thin(pixel);

				if (!thin) N = get_geometric_normal(pixel, world_pos, depth, normalize(lighting_data.camera_position.xyz - world_pos), N);

				float ao;
				vec3 bounce;
				vec3 bent;
				get_ambient_occlusion(in_uv, world_pos, N, ao, bounce, bent);

				if (thin) bent = N;
				else {
					bent = rotate_between(bent, N, shading_normal);

					float horizontal_face = smoothstep(0.5, 0.9, abs(shading_normal.y));
					vec3 lean = bent - shading_normal;
					bent = normalize(shading_normal + vec3(lean.x * horizontal_face, lean.y, lean.z * horizontal_face));
				}

				set_color(bounce, ao, bent, -(lighting_data.view * vec4(world_pos, 1.0)).z);
			}
		]],
	},
	{
		name = "ambient_occlusion_temporal",
		ComputePass = true,
		ColorFormat = {
			{"r16g16b16a16_sfloat", {"bounce_ao", "rgba"}},
			{"r16g16b16a16_sfloat", {"bent_normal", "rgba"}},
		},
		framebuffer_count = 2,
		scale = SCALE,
		LocalSize = COMPUTE_LOCAL_SIZE,
		storage_images = {
			{
				binding_index = 0,
				attachment = 1,
				dst_stage = "compute",
			},
			{
				binding_index = 1,
				attachment = 2,
				dst_stage = "compute",
			},
		},
		uniform_buffers = {
			{
				name = "temporal_data",
				binding_index = 3,
				block = {
					gbuffer_layout.block,
					post_source.pre_exposure_block,
					{"raw_ao_tex", "int"},
					{"raw_bent_tex", "int"},
					{"history_ao_tex", "int"},
					{"history_bent_tex", "int"},
				},
				write = function(self, block)
					gbuffer_layout.WriteBlock(self, block)
					post_source.WritePreExposureBlock(self, block)
					local raw = render3d.pipelines.ambient_occlusion:GetFramebuffer(1)
					block.raw_ao_tex = self:GetTextureIndex(raw:GetAttachment(1))
					block.raw_bent_tex = self:GetTextureIndex(raw:GetAttachment(2))
					local frame = system.GetFrameNumber()

					if self.history_framebuffers ~= self.framebuffers then
						self.history_framebuffers = self.framebuffers
						self.history_reset_frame = frame
					end

					if frame > self.history_reset_frame and render3d.ShouldUseLastFrameHistory() then
						local history = self:GetFramebuffer((frame + 1) % 2 + 1)
						block.history_ao_tex = self:GetTextureIndex(history:GetAttachment(1))
						block.history_bent_tex = self:GetTextureIndex(history:GetAttachment(2))
					else
						block.history_ao_tex = -1
						block.history_bent_tex = -1
					end

					return block
				end,
			},
		},
		custom_declarations = [[
			layout(set = 0, binding = 0, rgba16f) uniform writeonly image2D out_color;
			layout(set = 0, binding = 1, rgba16f) uniform writeonly image2D out_bent_normal;
			]],
		shader = [[
			]] .. compute_helpers.GetScreenHelpersGLSL() .. gbuffer_layout.GetDecodeGLSL("temporal_data") .. post_source.GetPreExposureGLSL("temporal_data") .. [[

			void main() {
				ivec2 pos = get_screen_pos();
				ivec2 size = imageSize(out_color);

				if (!is_screen_pos_in_bounds(pos, size)) return;

				vec4 current = texelFetch(TEXTURE(temporal_data.raw_ao_tex), pos, 0);
				vec4 current_bent = texelFetch(TEXTURE(temporal_data.raw_bent_tex), pos, 0);

				if (temporal_data.history_ao_tex == -1 || temporal_data.velocity_tex == -1 || current_bent.w == 0.0) {
					imageStore(out_color, pos, current);
					imageStore(out_bent_normal, pos, current_bent);
					return;
				}

				vec2 uv = get_screen_uv(pos, size);
				vec4 motion = texture(TEXTURE(temporal_data.velocity_tex), uv);
				vec2 history_uv = uv - motion.xy;

				float history_depth = texelFetch(TEXTURE(temporal_data.history_bent_tex), clamp(ivec2(history_uv * vec2(size)), ivec2(0), size - 1), 0).w;
				bool valid = history_uv.x > 0.0 && history_uv.x < 1.0 && history_uv.y > 0.0 && history_uv.y < 1.0 && history_depth > 0.0;
				float depth_error = abs(history_depth - motion.z) / max(motion.z, 0.1);
				float history_weight = 0.92 * (1.0 - smoothstep(0.05, 0.3, depth_error));

				if (!valid || history_weight <= 0.0) {
					imageStore(out_color, pos, current);
					imageStore(out_bent_normal, pos, current_bent);
					return;
				}

				vec4 mean = vec4(0.0);
				vec4 mean_squared = vec4(0.0);
				vec4 wide_mean = vec4(0.0);
				vec4 wide_squared = vec4(0.0);

				for (int y = -2; y <= 2; y++) {
					for (int x = -2; x <= 2; x++) {
						vec4 neighbor = texelFetch(TEXTURE(temporal_data.raw_ao_tex), clamp(pos + ivec2(x, y), ivec2(0), size - 1), 0);
						wide_mean += neighbor;
						wide_squared += neighbor * neighbor;

						if (abs(x) <= 1 && abs(y) <= 1) {
							mean += neighbor;
							mean_squared += neighbor * neighbor;
						}
					}
				}

				vec4 around = (mean - current) / 8.0;
				current.rgb = min(current.rgb, around.rgb * 2.0 + vec3(50.0 * get_pre_exposure()));
				mean /= 9.0;
				vec4 sigma = sqrt(max(mean_squared / 9.0 - mean * mean, vec4(0.0)));
				wide_mean /= 25.0;
				float wide_error = sqrt(max(wide_squared.a / 25.0 - wide_mean.a * wide_mean.a, 0.0)) / 5.0;
				vec4 history = texture(TEXTURE(temporal_data.history_ao_tex), history_uv);
				history.rgb *= get_pre_exposure() / get_previous_pre_exposure();
				history = clamp(history, mean - 2.0 * sigma, mean + 2.0 * sigma);
				history_weight *= 1.0 - smoothstep(wide_error, 3.0 * wide_error + 0.02, abs(history.a - wide_mean.a));
				vec4 history_bent = texture(TEXTURE(temporal_data.history_bent_tex), history_uv);
				imageStore(out_color, pos, mix(current, history, history_weight));
				imageStore(out_bent_normal, pos, vec4(mix(current_bent.xyz, history_bent.xyz, history_weight), current_bent.w));
			}
		]],
	},
	{
		name = "ambient_occlusion_blur",
		ComputePass = true,
		ColorFormat = {
			{"r16g16b16a16_sfloat", {"bounce_ao", "rgba"}},
			{"r16g16b16a16_sfloat", {"bent_normal", "rgba"}},
		},
		framebuffer_count = 1,
		LocalSize = COMPUTE_LOCAL_SIZE,
		storage_images = {
			{
				binding_index = 0,
				attachment = 1,
				dst_stage = "compute",
			},
			{
				binding_index = 1,
				attachment = 2,
				dst_stage = "compute",
			},
		},
		uniform_buffers = {
			{
				name = "ao_blur_data",
				binding_index = 3,
				block = {
					render3d.camera_block,
					gbuffer_layout.block,
					{"ao_tex", "int"},
					{"bent_tex", "int"},
				},
				write = function(self, block)
					render3d.WriteCameraBlock(self, block)
					gbuffer_layout.WriteBlock(self, block)
					local framebuffer = render3d.pipelines.ambient_occlusion_temporal:GetFramebuffer(system.GetFrameNumber() % 2 + 1)
					block.ao_tex = self:GetTextureIndex(framebuffer:GetAttachment(1))
					block.bent_tex = self:GetTextureIndex(framebuffer:GetAttachment(2))
					return block
				end,
			},
		},
		custom_declarations = [[
			layout(set = 0, binding = 0, rgba16f) uniform writeonly image2D out_color;
			layout(set = 0, binding = 1, rgba16f) uniform writeonly image2D out_bent_normal;
			]],
		shader = [[
			]] .. compute_helpers.GetScreenHelpersGLSL() .. gbuffer_layout.GetDecodeGLSL("ao_blur_data") .. [[

			void set_color(vec4 bounce_ao, vec3 bent) {
				imageStore(out_color, get_screen_pos(), bounce_ao);
				imageStore(out_bent_normal, get_screen_pos(), vec4(bent, 1.0));
			}

			void main() {
				ivec2 pos = get_screen_pos();
				ivec2 size = imageSize(out_color);

				if (!is_screen_pos_in_bounds(pos, size)) return;

				float depth = gbuffer_depth(pos);

				if (depth == 0.0) {
					set_color(vec4(0.0, 0.0, 0.0, 1.0), vec3(0.0));
					return;
				}

				mat4 inv_projection = ao_blur_data.inv_projection;
				float view_depth = -(inv_projection[2][2] * depth + inv_projection[3][2]) / (inv_projection[2][3] * depth + inv_projection[3][3]);
				float depth_sigma = max(]] .. BLUR_DEPTH_SIGMA .. [[ * view_depth, 0.005);
				ivec2 ao_size = textureSize(TEXTURE(ao_blur_data.ao_tex), 0);
				ivec2 base = pos / ]] .. RATIO .. [[;
				vec3 center_normal = gbuffer_normal(pos);
				bool center_thin = gbuffer_is_thin(pos);
				vec4 total = vec4(0.0);
				vec3 total_bent = vec3(0.0);
				float weight_sum = 0.0;

				for (int y = -1; y <= 2; y++) {
					for (int x = -1; x <= 2; x++) {
						ivec2 texel = clamp(base + ivec2(x, y), ivec2(0), ao_size - 1);
						vec4 bent = texelFetch(TEXTURE(ao_blur_data.bent_tex), texel, 0);
						float texel_depth = bent.w;

						if (texel_depth <= 0.0) continue;

						vec2 offset = vec2(pos - texel * ]] .. RATIO .. [[);
						float depth_diff = texel_depth - view_depth;
						float depth_weight = exp(-(depth_diff * depth_diff) / (2.0 * depth_sigma * depth_sigma));
						float spatial_weight = exp(-dot(offset, offset) / (2.0 * ]] .. BLUR_DISTANCE_SIGMA .. [[.0 * ]] .. BLUR_DISTANCE_SIGMA .. [[.0));
						float normal_weight = center_thin ? 1.0 : pow(max(dot(center_normal, gbuffer_normal(texel * ]] .. RATIO .. [[)), 0.0), ]] .. BLUR_NORMAL_POWER .. [[.0);
						float weight = depth_weight * spatial_weight * normal_weight;
						total += texelFetch(TEXTURE(ao_blur_data.ao_tex), texel, 0) * weight;
						total_bent += bent.xyz * weight;
						weight_sum += weight;
					}
				}

				if (weight_sum > 0.0001) {
					set_color(total / weight_sum, total_bent / weight_sum);
				} else {
					ivec2 texel = clamp(base + (pos & 1), ivec2(0), ao_size - 1);
					set_color(texelFetch(TEXTURE(ao_blur_data.ao_tex), texel, 0), texelFetch(TEXTURE(ao_blur_data.bent_tex), texel, 0).xyz);
				}
			}
		]],
	},
}
