local assets = import("goluwa/assets.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local screen_reconstruct = import("goluwa/render3d/screen_reconstruct.lua")
local system = import("goluwa/system.lua")
local compute_helpers = import("goluwa/render3d/compute_helpers.lua")
local COMPUTE_LOCAL_SIZE = {x = 8, y = 8, z = 1}
local TILE_WIDTH = COMPUTE_LOCAL_SIZE.x + 2
local TILE_HEIGHT = COMPUTE_LOCAL_SIZE.y + 2

local function get_previous_ssr_texture()
	if not render3d.pipelines.ssr or not render3d.pipelines.ssr.framebuffers then
		return nil
	end

	local prev_idx = (system.GetFrameNumber() + 1) % 2 + 1
	local prev_fb = render3d.pipelines.ssr:GetFramebuffer(prev_idx)

	if not prev_fb or not prev_fb.initialized then return nil end

	return prev_fb:GetAttachment(1)
end

return {
	{
		name = "ssr",
		ComputePass = true,
		ColorFormat = {{"r16g16b16a16_sfloat", {"ssr", "rgba"}}},
		framebuffer_count = 2,
		LocalSize = COMPUTE_LOCAL_SIZE,
		storage_images = {
			{
				binding_index = 0,
				attachment = 1,
				dst_stage = {"compute", "fragment"},
			},
		},
		uniform_buffers = {
			{
				name = "ssr_data",
				binding_index = 3,
				block = {
					render3d.camera_block,
					render3d.gbuffer_block,
					render3d.last_frame_block,
					{"history_ssr_tex", "int"},
					{"blue_noise_tex", "int"},
					{"prev_view", "mat4"},
					{"prev_projection", "mat4"},
					{"frame_index", "int"},
				},
				write = function(self, block)
					render3d.WriteCameraBlock(self, block)
					render3d.WriteGBufferBlock(self, block)
					render3d.WriteLastFrameBlock(self, block)
					local history = get_previous_ssr_texture()

					if history then
						block.history_ssr_tex = self:GetTextureIndex(history)
					else
						block.history_ssr_tex = -1
					end

					block.blue_noise_tex = self:GetTextureIndex(assets.GetTexture("textures/render/blue_noise.lua"))
					local prev_view = render3d.prev_view_matrix
					local prev_projection = render3d.prev_projection_matrix

					if prev_view then
						prev_view:CopyToFloatPointer(block.prev_view)
					else
						render3d.camera:BuildViewMatrix():CopyToFloatPointer(block.prev_view)
					end

					if prev_projection then
						prev_projection:CopyToFloatPointer(block.prev_projection)
					else
						render3d.camera:BuildProjectionMatrix():CopyToFloatPointer(block.prev_projection)
					end

					render3d.ssr_frame_count = (render3d.ssr_frame_count or 0) + 1
					block.frame_index = render3d.ssr_frame_count % 256
					return block
				end,
			},
		},
		custom_declarations = [[
			layout(set = 0, binding = 0, rgba16f) uniform writeonly image2D out_ssr;
		]],
		shader = [[
		]] .. compute_helpers.GetScreenHelpersGLSL() .. [[
		]] .. screen_reconstruct.GetWorldPosFromUVGLSL("ssr_data") .. [[
			#define SSR_MAX_STEPS 64
			#define SSR_BINARY_STEPS 8
			#define SSR_ROUGHNESS_CUTOFF 1
			#define SSR_TILE_WIDTH ]] .. tostring(TILE_WIDTH) .. "\n" .. [[
			#define SSR_TILE_HEIGHT ]] .. tostring(TILE_HEIGHT) .. "\n" .. [[
			#define PI 3.14159265359

			shared vec4 ssr_tile[SSR_TILE_HEIGHT][SSR_TILE_WIDTH];

			float saturate(float x) {
				return clamp(x, 0.0, 1.0);
			}

			vec2 get_clamped_screen_uv(ivec2 pos, ivec2 size) {
				ivec2 clamped = clamp(pos, ivec2(0), size - ivec2(1));
				return get_screen_uv(clamped, size);
			}

			float get_depth(vec2 uv) {
				return texture(TEXTURE(ssr_data.depth_tex), uv).r;
			}

			vec3 get_normal(vec2 uv) {
				return texture(TEXTURE(ssr_data.normal_tex), uv).xyz;
			}

			float get_roughness(vec2 uv) {
				return texture(TEXTURE(ssr_data.mra_tex), uv).g;
			}

			vec2 blue_noise(ivec2 pixel, int frame) {
				ivec2 noise_size = textureSize(TEXTURE(ssr_data.blue_noise_tex), 0);
				ivec2 offset = ivec2(
					int(fract(float(frame) * 0.7548776662466927) * float(noise_size.x)),
					int(fract(float(frame) * 0.5698402909980532) * float(noise_size.y))
				);
				return texelFetch(TEXTURE(ssr_data.blue_noise_tex), (pixel + offset) % noise_size, 0).rg;
			}

			vec3 sampleGGXVNDF(vec3 Ve, float alpha, vec2 xi) {
				vec3 Vh = normalize(vec3(alpha * Ve.x, alpha * Ve.y, Ve.z));
				float lensq = Vh.x * Vh.x + Vh.y * Vh.y;
				vec3 T1 = lensq > 0.0 ? vec3(-Vh.y, Vh.x, 0.0) / sqrt(lensq) : vec3(1.0, 0.0, 0.0);
				vec3 T2 = cross(Vh, T1);
				float r = sqrt(xi.x);
				float phi = 2.0 * PI * xi.y;
				float t1 = r * cos(phi);
				float t2 = r * sin(phi);
				float s = 0.5 * (1.0 + Vh.z);
				t2 = (1.0 - s) * sqrt(1.0 - t1 * t1) + s * t2;
				vec3 Nh = t1 * T1 + t2 * T2 + sqrt(max(0.0, 1.0 - t1 * t1 - t2 * t2)) * Vh;
				return normalize(vec3(alpha * Nh.x, alpha * Nh.y, max(0.0, Nh.z)));
			}

			void buildOrthonormalBasis(vec3 n, out vec3 t, out vec3 b) {
				float a = 1.0 / (1.0 + n.z);
				float d = -n.x * n.y * a;
				t = vec3(1.0 - n.x * n.x * a, d, -n.x);
				b = vec3(d, 1.0 - n.y * n.y * a, -n.y);
			}

			vec4 cast_ssr_ray(vec3 world_pos, vec3 N, vec3 V, float roughness, vec2 xi) {
				if (ssr_data.last_frame_tex == -1) return vec4(0.0);
				if (roughness > SSR_ROUGHNESS_CUTOFF) return vec4(0.0);

				vec3 N_vs = normalize(mat3(ssr_data.view) * N);
				vec3 V_vs = normalize(mat3(ssr_data.view) * V);
				vec4 pos_vs = ssr_data.view * vec4(world_pos, 1.0);

				vec3 T;
				vec3 B;
				buildOrthonormalBasis(N_vs, T, B);

				vec3 V_local = vec3(dot(V_vs, T), dot(V_vs, B), dot(V_vs, N_vs));
				float alpha = max(0.001, roughness * roughness);
				vec3 H_local = sampleGGXVNDF(V_local, alpha, xi);
				vec3 H_vs = normalize(T * H_local.x + B * H_local.y + N_vs * H_local.z);

				vec3 R_vs = reflect(-V_vs, H_vs);
				if (dot(N_vs, R_vs) < 0.0) return vec4(0.0);

				float jitter = fract(xi.x * 12.9898 + xi.y * 78.233);
				float step_size = 0.05 + 0.05 * jitter;
				vec3 current_pos = pos_vs.xyz + R_vs * step_size * jitter;
				int steps = int(mix(float(SSR_MAX_STEPS), float(SSR_MAX_STEPS / 2), roughness));

				for (int i = 0; i < steps; i++) {
					current_pos += R_vs * step_size;
					vec4 proj = ssr_data.projection * vec4(current_pos, 1.0);
					proj.xyz /= proj.w;
					vec2 uv = proj.xy * 0.5 + 0.5;

					if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) break;

					float sampled_depth = texture(TEXTURE(ssr_data.depth_tex), uv).r;
					vec4 sampled_clip = vec4(uv * 2.0 - 1.0, sampled_depth, 1.0);
					vec4 sampled_view = ssr_data.inv_projection * sampled_clip;
					sampled_view /= sampled_view.w;

					if (current_pos.z < sampled_view.z) {
						float depth_diff = abs(current_pos.z - sampled_view.z);
						float thickness = 0.5 + step_size * 2.0;
						thickness *= 1.0 + length(current_pos) * 0.005;

						if (depth_diff < thickness) {
							vec3 start = current_pos - R_vs * step_size;
							vec3 end = current_pos;

							for (int j = 0; j < SSR_BINARY_STEPS; j++) {
								vec3 mid = mix(start, end, 0.5);
								vec4 mid_proj = ssr_data.projection * vec4(mid, 1.0);
								mid_proj.xyz /= mid_proj.w;
								vec2 mid_uv = mid_proj.xy * 0.5 + 0.5;
								float mid_depth = texture(TEXTURE(ssr_data.depth_tex), mid_uv).r;
								vec4 mid_clip = vec4(mid_uv * 2.0 - 1.0, mid_depth, 1.0);
								vec4 mid_view = ssr_data.inv_projection * mid_clip;
								mid_view /= mid_view.w;

								if (mid.z < mid_view.z) {
									end = mid;
									uv = mid_uv;
								} else {
									start = mid;
								}
							}

							vec3 hit_normal_ws = texture(TEXTURE(ssr_data.normal_tex), uv).xyz;
							vec3 hit_normal_vs = normalize(mat3(ssr_data.view) * hit_normal_ws);

							if (dot(hit_normal_vs, -R_vs) < 0.0) {
								step_size *= 1.5;
								continue;
							}

							vec3 hit_color;
							float dist = length(current_pos - pos_vs.xyz);

							if (roughness > 0.1) {
								vec2 tex_size = vec2(textureSize(TEXTURE(ssr_data.last_frame_tex), 0));
								float cone = roughness * dist * 0.05;
								float mip = log2(max(1.0, cone * max(tex_size.x, tex_size.y)));
								hit_color = textureLod(TEXTURE(ssr_data.last_frame_tex), uv, min(mip, 4.0)).rgb;
							} else {
								hit_color = texture(TEXTURE(ssr_data.last_frame_tex), uv).rgb;
							}

							float edge_fade = 1.0 - pow(max(abs(uv.x - 0.5), abs(uv.y - 0.5)) * 2.0, 3.0);
							float dist_fade = 1.0 - saturate(dist / 100.0);
							float thick_conf = 1.0 - saturate(depth_diff / thickness);
							float confidence = edge_fade * dist_fade * thick_conf;
							return vec4(hit_color, confidence);
						}
					}

					step_size *= 1.05;
				}

				return vec4(0.0);
			}

			vec4 compute_current_ssr(ivec2 sample_pos, ivec2 size) {
				vec2 uv = get_clamped_screen_uv(sample_pos, size);
				float depth = get_depth(uv);

				if (depth == 1.0) {
					return vec4(0.0);
				}

				vec3 N = get_normal(uv);
				float roughness = get_roughness(uv);
				vec3 world_pos = get_world_pos(uv, depth);
				vec3 V = normalize(ssr_data.camera_position.xyz - world_pos);
				ivec2 clamped_pos = clamp(sample_pos, ivec2(0), size - ivec2(1));
				vec2 xi = blue_noise(clamped_pos, ssr_data.frame_index);
				return cast_ssr_ray(world_pos, N, V, roughness, xi);
			}

			void write_tile_sample(ivec2 tile_pos, ivec2 sample_pos, ivec2 size) {
				ssr_tile[tile_pos.y][tile_pos.x] = compute_current_ssr(sample_pos, size);
			}

			vec4 resolve_current_ssr(ivec2 pos, ivec2 size, ivec2 local_pos, vec4 current) {
				if (ssr_data.history_ssr_tex == -1) {
					return current;
				}

				vec2 uv = get_screen_uv(pos, size);
				float depth = get_depth(uv);

				if (depth == 1.0) {
					return current;
				}

				vec3 world_pos = get_world_pos(uv, depth);
				vec4 prev_clip = ssr_data.prev_projection * (ssr_data.prev_view * vec4(world_pos, 1.0));

				if (abs(prev_clip.w) <= 0.00001) {
					return current;
				}

				vec2 prev_uv = (prev_clip.xy / prev_clip.w) * 0.5 + 0.5;

				if (prev_uv.x < 0.0 || prev_uv.x > 1.0 || prev_uv.y < 0.0 || prev_uv.y > 1.0) {
					return current;
				}

				vec4 history = texture(TEXTURE(ssr_data.history_ssr_tex), prev_uv);
				vec3 m1 = vec3(0.0);
				vec3 m2 = vec3(0.0);
				float a1 = 0.0;
				float a2 = 0.0;

				for (int y = -1; y <= 1; y++) {
					for (int x = -1; x <= 1; x++) {
						vec4 sample_value = ssr_tile[local_pos.y + 1 + y][local_pos.x + 1 + x];
						m1 += sample_value.rgb;
						m2 += sample_value.rgb * sample_value.rgb;
						a1 += sample_value.a;
						a2 += sample_value.a * sample_value.a;
					}
				}

				m1 /= 9.0;
				m2 /= 9.0;
				a1 /= 9.0;
				a2 /= 9.0;

				vec3 sigma = sqrt(max(vec3(0.0), m2 - m1 * m1));
				float sigma_a = sqrt(max(0.0, a2 - a1 * a1));
				float gamma = 1.5;
				vec3 clamped_rgb = clamp(history.rgb, m1 - sigma * gamma, m1 + sigma * gamma);
				float clamped_a = clamp(history.a, a1 - sigma_a * gamma, a1 + sigma_a * gamma);
				vec4 clamped_history = vec4(clamped_rgb, clamped_a);
				float blend = 0.5;
				float clamp_diff = length(history.rgb - clamped_rgb);
				blend *= 1.0 - saturate(clamp_diff * 2.0);
				return mix(current, clamped_history, blend);
			}

			void main() {
				ivec2 pos = get_screen_pos();
				ivec2 size = imageSize(out_ssr);

				if (!is_screen_pos_in_bounds(pos, size)) return;

				ivec2 local_pos = ivec2(gl_LocalInvocationID.xy);
				ivec2 tile_pos = local_pos + ivec2(1);

				write_tile_sample(tile_pos, pos, size);

				if (local_pos.x == 0) {
					write_tile_sample(ivec2(0, tile_pos.y), pos + ivec2(-1, 0), size);
				}

				if (local_pos.x == ]] .. tostring(COMPUTE_LOCAL_SIZE.x - 1) .. [[) {
					write_tile_sample(ivec2(SSR_TILE_WIDTH - 1, tile_pos.y), pos + ivec2(1, 0), size);
				}

				if (local_pos.y == 0) {
					write_tile_sample(ivec2(tile_pos.x, 0), pos + ivec2(0, -1), size);
				}

				if (local_pos.y == ]] .. tostring(COMPUTE_LOCAL_SIZE.y - 1) .. [[) {
					write_tile_sample(ivec2(tile_pos.x, SSR_TILE_HEIGHT - 1), pos + ivec2(0, 1), size);
				}

				if (local_pos.x == 0 && local_pos.y == 0) {
					write_tile_sample(ivec2(0, 0), pos + ivec2(-1, -1), size);
				}

				if (local_pos.x == ]] .. tostring(COMPUTE_LOCAL_SIZE.x - 1) .. [[ && local_pos.y == 0) {
					write_tile_sample(ivec2(SSR_TILE_WIDTH - 1, 0), pos + ivec2(1, -1), size);
				}

				if (local_pos.x == 0 && local_pos.y == ]] .. tostring(COMPUTE_LOCAL_SIZE.y - 1) .. [[) {
					write_tile_sample(ivec2(0, SSR_TILE_HEIGHT - 1), pos + ivec2(-1, 1), size);
				}

				if (local_pos.x == ]] .. tostring(COMPUTE_LOCAL_SIZE.x - 1) .. [[ && local_pos.y == ]] .. tostring(COMPUTE_LOCAL_SIZE.y - 1) .. [[) {
					write_tile_sample(ivec2(SSR_TILE_WIDTH - 1, SSR_TILE_HEIGHT - 1), pos + ivec2(1, 1), size);
				}

				memoryBarrierShared();
				barrier();

				vec4 current = ssr_tile[tile_pos.y][tile_pos.x];
				vec4 resolved = resolve_current_ssr(pos, size, local_pos, current);
				imageStore(out_ssr, pos, resolved);
			}
		]],
	},
}
