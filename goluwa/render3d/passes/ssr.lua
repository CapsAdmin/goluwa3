local assets = import("goluwa/assets.lua")
local ibl = import("goluwa/render3d/ibl.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local screen_reconstruct = import("goluwa/render3d/screen_reconstruct.lua")
local system = import("goluwa/system.lua")
local compute_helpers = import("goluwa/render3d/compute_helpers.lua")
local COMPUTE_LOCAL_SIZE = {x = 8, y = 8, z = 1}
local MAX_PROBES = 64
return {
	{
		name = "ssr",
		ComputePass = true,
		ColorFormat = {
			{"r16g16b16a16_sfloat", {"ssr", "rgba"}},
			{"r32_sfloat", {"ssr_depth", "r"}},
		},
		framebuffer_count = 2,
		scale = 0.5,
		LocalSize = COMPUTE_LOCAL_SIZE,
		storage_images = {
			{
				binding_index = 0,
				attachment = 1,
				dst_stage = {"compute", "fragment"},
			},
			{
				binding_index = 1,
				attachment = 2,
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
					{"blue_noise_tex", "int"},
					{"env_tex", "int"},
					{"history_tex", "int"},
					{"history_depth_tex", "int"},
					{"frame_index", "int"},
					{"probe_color_textures", "int", 64},
					{"probe_depth_textures", "int", 64},
					{"probe_positions", "vec4", 64},
					{"prev_view", "mat4"},
					{"prev_projection", "mat4"},
				},
				write = function(self, block)
					render3d.WriteCameraBlock(self, block)
					render3d.WriteGBufferBlock(self, block)
					render3d.WriteLastFrameBlock(self, block)
					block.blue_noise_tex = self:GetTextureIndex(assets.GetTexture("textures/render/blue_noise.lua"))
					block.env_tex = self:GetCubeMapTextureIndex(render3d.GetEnvironmentTexture())
					local frame = system.GetFrameNumber()
					block.frame_index = frame

					-- history is the framebuffer written last frame. recreated framebuffers hold garbage
					-- until they have been written once, so skip history for one frame after that
					if self.ssr_history_framebuffers ~= self.framebuffers then
						self.ssr_history_framebuffers = self.framebuffers
						self.ssr_history_reset_frame = frame
					end

					if render3d.ShouldUseLastFrameHistory() and frame > self.ssr_history_reset_frame then
						local history_fb = self:GetFramebuffer((frame + 1) % 2 + 1)
						block.history_tex = self:GetTextureIndex(history_fb:GetAttachment(1))
						block.history_depth_tex = self:GetTextureIndex(history_fb:GetAttachment(2))
					else
						block.history_tex = -1
						block.history_depth_tex = -1
					end

					for i = 0, MAX_PROBES - 1 do
						block.probe_color_textures[i] = -1
						block.probe_depth_textures[i] = -1
						block.probe_positions[i][0] = 0
						block.probe_positions[i][1] = 0
						block.probe_positions[i][2] = 0
						block.probe_positions[i][3] = 0
					end

					local lightprobes = import.loaded["goluwa/render3d/lightprobes.lua"] or
						import("goluwa/render3d/lightprobes.lua")

					if
						lightprobes.IsEnabled() and
						lightprobes.AreSceneProbesEnabled() and
						render3d.ShouldUseProbeReflections()
					then
						local probes = lightprobes.GetProbes()

						for i = 0, MAX_PROBES - 1 do
							local probe = probes[i + 1]

							if probe then
								if probe.cubemap then
									block.probe_color_textures[i] = self:GetCubeMapTextureIndex(probe.cubemap)
								end

								if probe.depth_cubemap then
									block.probe_depth_textures[i] = self:GetCubeMapTextureIndex(probe.depth_cubemap)
								end

								block.probe_positions[i][0] = probe.position.x
								block.probe_positions[i][1] = probe.position.y
								block.probe_positions[i][2] = probe.position.z
								block.probe_positions[i][3] = probe.radius or 20
							end
						end
					end

					local prev_view = render3d.GetPreviousViewMatrix()
					local prev_projection = render3d.GetPreviousProjectionMatrix()

					if prev_view then
						prev_view:CopyToFloatPointer(block.prev_view)
					else
						render3d.GetRenderCamera():BuildViewMatrix():CopyToFloatPointer(block.prev_view)
					end

					if prev_projection then
						prev_projection:CopyToFloatPointer(block.prev_projection)
					else
						render3d.GetRenderCamera():BuildProjectionMatrix():CopyToFloatPointer(block.prev_projection)
					end

					return block
				end,
			},
		},
		custom_declarations = [[
			layout(set = 0, binding = 0, rgba16f) uniform writeonly image2D out_ssr;
			layout(set = 0, binding = 1, r32f) uniform writeonly image2D out_ssr_depth;
		]],
		shader = [[
		]] .. compute_helpers.GetScreenHelpersGLSL() .. [[
		]] .. ibl.GetBRDFGLSLCode() .. [[
		]] .. ibl.GetEnvironmentGLSLCode() .. [[
		]] .. screen_reconstruct.GetWorldPosFromUVGLSL("ssr_data") .. [[
			#define SSR_MAX_STEPS 48
			#define SSR_BINARY_STEPS 6
			#define SSR_STRIDE 2.0
			#define SSR_MAX_DISTANCE 80.0
			#define SSR_ROUGHNESS_CUTOFF 0.75
			#define SSR_MIRROR_THRESHOLD 0.06
			#define SSR_MAX_HIT_LUMINANCE 8.0
			#define SSR_SPATIAL_NORMAL_POWER 32.0
			#define SSR_TILE_WIDTH ]] .. tostring(COMPUTE_LOCAL_SIZE.x) .. "\n" .. [[
			#define SSR_TILE_HEIGHT ]] .. tostring(COMPUTE_LOCAL_SIZE.y) .. "\n" .. [[

			shared vec4 ssr_tile[SSR_TILE_HEIGHT][SSR_TILE_WIDTH];
			shared float ssr_tile_depth[SSR_TILE_HEIGHT][SSR_TILE_WIDTH];
			shared vec3 ssr_tile_normal[SSR_TILE_HEIGHT][SSR_TILE_WIDTH];

			ivec2 ssr_size;
			ivec2 gbuffer_size;
			vec2 gbuffer_ratio;
			vec4 inv_projection_row_z;
			vec4 inv_projection_row_w;

			float luminance(vec3 color) {
				return dot(color, vec3(0.2126, 0.7152, 0.0722));
			}

			float linearize_depth(vec2 uv, float depth) {
				vec4 clip = vec4(uv * 2.0 - 1.0, depth, 1.0);
				return dot(inv_projection_row_z, clip) / dot(inv_projection_row_w, clip);
			}

			vec3 get_view_pos(vec2 uv, float depth) {
				vec4 view_pos = ssr_data.inv_projection * vec4(uv * 2.0 - 1.0, depth, 1.0);
				return view_pos.xyz / view_pos.w;
			}

			float fetch_depth(vec2 uv) {
				return texelFetch(TEXTURE(ssr_data.depth_tex), clamp(ivec2(uv * vec2(gbuffer_size)), ivec2(0), gbuffer_size - 1), 0).r;
			}

			vec2 blue_noise(ivec2 pixel) {
				ivec2 noise_size = textureSize(TEXTURE(ssr_data.blue_noise_tex), 0);
				vec2 xi = texelFetch(TEXTURE(ssr_data.blue_noise_tex), pixel % noise_size, 0).rg;
				// R2 sequence offset per frame keeps the pattern blue in space but different in time
				return fract(xi + float(ssr_data.frame_index % 64) * vec2(0.7548776662, 0.5698402910));
			}

			void buildOrthonormalBasis(vec3 n, out vec3 t, out vec3 b) {
				float a = 1.0 / (1.0 + n.z);
				float d = -n.x * n.y * a;
				t = vec3(1.0 - n.x * n.x * a, d, -n.x);
				b = vec3(d, 1.0 - n.y * n.y * a, -n.y);
			}

			vec2 get_last_frame_uv(vec3 hit_view_pos) {
				vec4 world_hit = ssr_data.inv_view * vec4(hit_view_pos, 1.0);
				vec4 prev_clip = ssr_data.prev_projection * (ssr_data.prev_view * vec4(world_hit.xyz, 1.0));

				if (abs(prev_clip.w) <= 1e-5) {
					return vec2(-1.0);
				}

				prev_clip /= prev_clip.w;
				return prev_clip.xy * 0.5 + 0.5;
			}

			vec3 correct_probe_depth_lookup_dir(vec3 dir) {
				return normalize(vec3(-dir.x, dir.y, dir.z));
			}

			vec3 correct_probe_color_lookup_dir(vec3 dir) {
				return normalize(dir);
			}

			vec3 parallax_depth(vec3 R, vec3 ray_origin, float sphere_radius, int depth_tex, out float hit_confidence) {
				const int MAX_MARCH_STEPS = 16;
				const int MAX_BINARY_STEPS = 6;
				float origin_len2 = dot(ray_origin, ray_origin);
				float radius2 = sphere_radius * sphere_radius;
				float b = dot(ray_origin, R);
				float c = origin_len2 - radius2;
				float discriminant = b * b - c;

				if (discriminant <= 0.0) {
					hit_confidence = 0.0;
					return normalize(ray_origin + R * sphere_radius);
				}

				float sphere_exit = -b + sqrt(discriminant);

				if (sphere_exit <= 0.0) {
					hit_confidence = 0.0;
					return normalize(ray_origin + R * sphere_radius);
				}

				float t_prev = 0.0;
				float march_step = max(sphere_exit / float(MAX_MARCH_STEPS), sphere_radius * 0.02);
				float t = min(march_step, sphere_exit);
				float closest_depth_gap = 1e20;
				float closest_gap_t = sphere_exit;

				for (int i = 0; i < MAX_MARCH_STEPS; i++) {
					vec3 ray_pos = ray_origin + R * t;
					vec3 ray_dir = normalize(ray_pos);
					float ray_dist = length(ray_pos);
					float stored_depth = texture(CUBEMAP(depth_tex), correct_probe_depth_lookup_dir(ray_dir)).r;
					float depth_gap = max(stored_depth - ray_dist, 0.0);

					if (depth_gap < closest_depth_gap) {
						closest_depth_gap = depth_gap;
						closest_gap_t = t;
					}

					if (ray_dist >= stored_depth) {
						vec3 hit_pos = ray_pos;
						float start_t = t_prev;
						float end_t = t;

						for (int j = 0; j < MAX_BINARY_STEPS; j++) {
							float mid_t = (start_t + end_t) * 0.5;
							vec3 mid_pos = ray_origin + R * mid_t;
							vec3 mid_dir = normalize(mid_pos);
							float mid_dist = length(mid_pos);
							float mid_depth = texture(CUBEMAP(depth_tex), correct_probe_depth_lookup_dir(mid_dir)).r;

							if (mid_dist >= mid_depth) {
								end_t = mid_t;
								hit_pos = mid_pos;
							} else {
								start_t = mid_t;
							}
						}

						hit_confidence = 1.0;
						return normalize(hit_pos);
					}

					if (t >= sphere_exit) {
						break;
					}

					t_prev = t;
					march_step *= 1.15;
					t = min(t + march_step, sphere_exit);
				}

				vec3 exit_pos = ray_origin + R * sphere_exit;
				vec3 exit_normal = normalize(exit_pos);
				float open_space_confidence = smoothstep(sphere_radius * 0.04, sphere_radius * 0.28, closest_depth_gap);
				float exit_alignment = saturate(dot(exit_normal, R));
				float directional_confidence = smoothstep(0.15, 0.65, exit_alignment);
				float blocker_proximity = 1.0 - smoothstep(0.35, 0.9, closest_gap_t / max(sphere_exit, 1e-5));
				float blocker_suppression = mix(1.0, 0.2, blocker_proximity);
				float miss_confidence = open_space_confidence * directional_confidence * blocker_suppression;
				hit_confidence = max(miss_confidence, 0.02);
				return normalize(exit_pos);
			}

			vec3 get_probe_environment_reflection(vec3 normal, float roughness, vec3 V, vec3 world_pos) {
				vec3 raw_R = reflect(-V, normal);
				vec3 R = get_specular_dominant_direction(raw_R, normal, roughness);
				vec3 global_env = sample_environment_specular(ssr_data.env_tex, R, normal, roughness);
				vec3 probes_env = vec3(0.0);
				float total_weight = 0.0;
				float normalized_weight_sum = 0.0;
				float max_weight = 0.0;

				for (int i = 0; i < 64; i++) {
					int color_tex = ssr_data.probe_color_textures[i];
					int depth_tex = ssr_data.probe_depth_textures[i];
					if (color_tex == -1) continue;

					vec3 probe_pos = ssr_data.probe_positions[i].xyz;
					float sphere_radius = ssr_data.probe_positions[i].w;
					vec3 probe_to_point = world_pos - probe_pos;
					float dist_to_point = length(probe_to_point);

					if (dist_to_point < sphere_radius) {
						vec3 dir_to_point = normalize(probe_to_point);
						float stored_depth = texture(CUBEMAP(depth_tex), correct_probe_depth_lookup_dir(dir_to_point)).r;
						float bias = 0.3;
						float fade_band = 0.75;
						float penetration = dist_to_point - (stored_depth + bias);
						float occlusion_weight = 1.0 - smoothstep(0.0, fade_band, max(penetration, 0.0));
						float depth_diff = abs(stored_depth - dist_to_point);

						if (occlusion_weight <= 0.001) continue;

						float depth_weight = exp(-depth_diff * 0.5);
						float edge_weight = smoothstep(sphere_radius, sphere_radius * 0.3, dist_to_point);
						float weight = depth_weight * edge_weight * occlusion_weight;

						if (weight > 0.001) {
							float normalized_weight = pow(weight, mix(4.0, 1.5, roughness));
							float hit_confidence;
							vec3 reflected = parallax_depth(R, probe_to_point, sphere_radius, depth_tex, hit_confidence);
							float probe_max_mip = color_tex == -1 ? 0.0 : float(textureQueryLevels(CUBEMAP(color_tex)) - 1);
							float probe_mip = roughness * probe_max_mip;
							vec3 probe_sample = textureLod(CUBEMAP(color_tex), correct_probe_color_lookup_dir(R), probe_mip).rgb;
							vec3 corrected_sample = textureLod(CUBEMAP(color_tex), correct_probe_color_lookup_dir(reflected), probe_mip).rgb;
							float correction_confidence = smoothstep(0.15, 0.85, hit_confidence);
							vec3 sample_color = mix(probe_sample, corrected_sample, correction_confidence);
							probes_env += sample_color * normalized_weight;
							total_weight += weight * hit_confidence;
							normalized_weight_sum += normalized_weight;
							max_weight = max(max_weight, weight * hit_confidence);
						}
					}
				}

				if (normalized_weight_sum > 0.001) {
					vec3 local_env = probes_env / normalized_weight_sum;
					float local_coverage = clamp(max_weight + total_weight * 0.35, 0.0, 1.0);
					return mix(global_env, local_env, local_coverage);
				}

				return global_env;
			}

			// marches in screen space: uv and z/w are linear in t along the projected segment, so each step
			// is one depth fetch and no matrix multiplies
			vec4 trace_ssr_direction(vec3 pos_vs, vec3 R_vs, float roughness, float jitter) {
				float ray_len = SSR_MAX_DISTANCE;

				if (pos_vs.z + R_vs.z * ray_len > -0.05) {
					ray_len = (-0.05 - pos_vs.z) / R_vs.z;
				}

				if (ray_len <= 1e-4) return vec4(0.0);

				vec3 end_vs = pos_vs + R_vs * ray_len;
				vec4 h0 = ssr_data.projection * vec4(pos_vs, 1.0);
				vec4 h1 = ssr_data.projection * vec4(end_vs, 1.0);
				float k0 = 1.0 / h0.w;
				float k1 = 1.0 / h1.w;
				vec2 p0 = h0.xy * k0 * 0.5 + 0.5;
				vec2 p1 = h1.xy * k1 * 0.5 + 0.5;
				float q0 = pos_vs.z * k0;
				float q1 = end_vs.z * k1;
				vec2 delta_px = (p1 - p0) * vec2(ssr_size);
				float pixel_len = max(abs(delta_px.x), abs(delta_px.y));
				int steps = clamp(int(pixel_len / SSR_STRIDE), 1, SSR_MAX_STEPS);
				float dt = 1.0 / float(steps);
				float t_prev = 0.0;
				float z_prev = pos_vs.z;
				float t = dt * jitter;

				for (int i = 0; i < steps; i++) {
					t = min(t + dt, 1.0);
					vec2 uv = mix(p0, p1, t);

					if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) break;

					float z_ray = mix(q0, q1, t) / mix(k0, k1, t);
					float depth = fetch_depth(uv);

					if (depth < 1.0) {
						float z_surf = linearize_depth(uv, depth);

						if (z_ray < z_surf) {
							float thickness = max(0.15, -z_surf * 0.03) + abs(z_ray - z_prev);
							float depth_diff = z_surf - z_ray;

							if (depth_diff < thickness) {
								float t_lo = t_prev;
								float t_hi = t;
								float refined_diff = depth_diff;

								for (int j = 0; j < SSR_BINARY_STEPS; j++) {
									float t_mid = (t_lo + t_hi) * 0.5;
									vec2 uv_mid = mix(p0, p1, t_mid);
									float z_mid = mix(q0, q1, t_mid) / mix(k0, k1, t_mid);
									float depth_mid = fetch_depth(uv_mid);
									// a sky sample counts as in front, so the search backs toward the last real surface
									float z_surf_mid = depth_mid < 1.0 ? linearize_depth(uv_mid, depth_mid) : -1e30;

									if (z_mid < z_surf_mid) {
										t_hi = t_mid;
										uv = uv_mid;
										depth = depth_mid;
										refined_diff = z_surf_mid - z_mid;
									} else {
										t_lo = t_mid;
									}
								}

								vec3 hit_normal_vs = mat3(ssr_data.view) * texture(TEXTURE(ssr_data.normal_tex), uv).xyz;

								if (dot(hit_normal_vs, R_vs) > 0.0) {
									t_prev = t;
									z_prev = z_ray;
									continue;
								}

								vec3 hit_vs = get_view_pos(uv, depth);
								vec2 last_frame_uv = get_last_frame_uv(hit_vs);

								if (last_frame_uv.x <= 0.0 || last_frame_uv.x >= 1.0 || last_frame_uv.y <= 0.0 || last_frame_uv.y >= 1.0) {
									return vec4(0.0);
								}

								float edge_fade = 1.0 - pow(max(abs(uv.x - 0.5), abs(uv.y - 0.5)) * 2.0, 3.0);
								edge_fade *= 1.0 - pow(max(abs(last_frame_uv.x - 0.5), abs(last_frame_uv.y - 0.5)) * 2.0, 3.0);
								float dist_fade = 1.0 - smoothstep(SSR_MAX_DISTANCE * 0.7, SSR_MAX_DISTANCE, length(hit_vs - pos_vs));
								// after refinement the ray sits just behind the surface it hit. a gap that is still large
								// means it went behind something thin rather than hitting it
								float thick_conf = 1.0 - saturate(refined_diff / max(0.15, -z_surf * 0.03));
								vec3 hit_color = texture(TEXTURE(ssr_data.last_frame_tex), last_frame_uv).rgb;

								if (roughness > SSR_MIRROR_THRESHOLD) {
									float hit_luma = luminance(hit_color);

									if (hit_luma > SSR_MAX_HIT_LUMINANCE) {
										hit_color *= SSR_MAX_HIT_LUMINANCE / hit_luma;
									}
								}

								return vec4(hit_color, edge_fade * dist_fade * thick_conf);
							}
						}
					}

					t_prev = t;
					z_prev = z_ray;
				}

				return vec4(0.0);
			}

			vec4 cast_ssr_ray(vec3 world_pos, vec3 pos_vs, vec3 N, vec3 V, float roughness, vec2 xi) {
				vec3 fallback_reflection = get_probe_environment_reflection(N, roughness, V, world_pos);
				if (ssr_data.last_frame_tex == -1) return vec4(fallback_reflection, 0.0);
				if (roughness > SSR_ROUGHNESS_CUTOFF) return vec4(fallback_reflection, 0.0);

				vec3 N_vs = normalize(mat3(ssr_data.view) * N);
				vec3 V_vs = normalize(-pos_vs);
				vec3 mirror_R_vs = reflect(-V_vs, N_vs);

				if (dot(N_vs, mirror_R_vs) < 0.0) return vec4(fallback_reflection, 0.0);

				vec3 R_vs = mirror_R_vs;

				if (roughness > SSR_MIRROR_THRESHOLD) {
					vec3 T;
					vec3 B;
					buildOrthonormalBasis(N_vs, T, B);
					vec3 V_local = vec3(dot(V_vs, T), dot(V_vs, B), dot(V_vs, N_vs));
					vec3 H_local = ImportanceSampleGGXVNDF(V_local, max(0.001, roughness * roughness), xi);
					vec3 H_vs = normalize(T * H_local.x + B * H_local.y + N_vs * H_local.z);
					float rough_mix = smoothstep(SSR_MIRROR_THRESHOLD, SSR_MIRROR_THRESHOLD * 3.0, roughness);
					R_vs = normalize(mix(mirror_R_vs, reflect(-V_vs, H_vs), rough_mix));

					if (dot(N_vs, R_vs) < 0.001) R_vs = mirror_R_vs;
				}

				vec4 hit = trace_ssr_direction(pos_vs, R_vs, roughness, xi.y);
				return vec4(mix(fallback_reflection, hit.rgb, hit.a), hit.a);
			}

			void main() {
				ivec2 pos = get_screen_pos();
				ssr_size = imageSize(out_ssr);
				gbuffer_size = textureSize(TEXTURE(ssr_data.depth_tex), 0);
				gbuffer_ratio = vec2(gbuffer_size) / vec2(ssr_size);
				mat4 inv_projection = ssr_data.inv_projection;
				inv_projection_row_z = vec4(inv_projection[0][2], inv_projection[1][2], inv_projection[2][2], inv_projection[3][2]);
				inv_projection_row_w = vec4(inv_projection[0][3], inv_projection[1][3], inv_projection[2][3], inv_projection[3][3]);
				ivec2 local_pos = ivec2(gl_LocalInvocationID.xy);
				// every invocation has to reach the barrier, so out of bounds threads only skip the work
				bool in_bounds = is_screen_pos_in_bounds(pos, ssr_size);
				ivec2 gbuffer_pos = min(ivec2((vec2(pos) + 0.5) * gbuffer_ratio), gbuffer_size - 1);
				vec2 uv = (vec2(gbuffer_pos) + 0.5) / vec2(gbuffer_size);
				float depth = in_bounds ? texelFetch(TEXTURE(ssr_data.depth_tex), gbuffer_pos, 0).r : 1.0;
				vec4 current = vec4(0.0);
				vec3 N = vec3(0.0, 1.0, 0.0);
				vec3 world_pos = vec3(0.0);
				float roughness = 1.0;
				float view_depth = 0.0;

				if (depth < 1.0) {
					N = texelFetch(TEXTURE(ssr_data.normal_tex), gbuffer_pos, 0).xyz;
					roughness = texelFetch(TEXTURE(ssr_data.mra_tex), gbuffer_pos, 0).g;
					world_pos = get_world_pos(uv, depth);
					vec3 pos_vs = (ssr_data.view * vec4(world_pos, 1.0)).xyz;
					view_depth = -pos_vs.z;
					vec3 V = normalize(ssr_data.camera_position.xyz - world_pos);
					current = cast_ssr_ray(world_pos, pos_vs, N, V, roughness, blue_noise(pos));
				}

				ssr_tile[local_pos.y][local_pos.x] = current;
				ssr_tile_depth[local_pos.y][local_pos.x] = view_depth;
				ssr_tile_normal[local_pos.y][local_pos.x] = N;
				memoryBarrierShared();
				barrier();

				if (!in_bounds) return;

				if (depth >= 1.0) {
					imageStore(out_ssr, pos, vec4(0.0));
					imageStore(out_ssr_depth, pos, vec4(0.0));
					return;
				}

				vec4 accum = vec4(0.0);
				vec3 moment1 = vec3(0.0);
				vec3 moment2 = vec3(0.0);
				float total_weight = 0.0;

				for (int y = -1; y <= 1; y++) {
					for (int x = -1; x <= 1; x++) {
						ivec2 tile_pos = local_pos + ivec2(x, y);

						if (tile_pos.x < 0 || tile_pos.y < 0 || tile_pos.x >= SSR_TILE_WIDTH || tile_pos.y >= SSR_TILE_HEIGHT) continue;

						float sample_depth = ssr_tile_depth[tile_pos.y][tile_pos.x];

						if (sample_depth <= 0.0) continue;

						float depth_weight = exp(-abs(sample_depth - view_depth) / max(view_depth * 0.05, 0.05));
						float normal_weight = pow(max(dot(N, ssr_tile_normal[tile_pos.y][tile_pos.x]), 0.0), SSR_SPATIAL_NORMAL_POWER);
						float weight = depth_weight * normal_weight;

						if (weight <= 0.0001) continue;

						vec4 sample_value = ssr_tile[tile_pos.y][tile_pos.x];
						accum += sample_value * weight;
						moment1 += sample_value.rgb * weight;
						moment2 += sample_value.rgb * sample_value.rgb * weight;
						total_weight += weight;
					}
				}

				vec4 filtered = current;
				vec3 mean = current.rgb;
				vec3 deviation = vec3(0.0);

				if (total_weight > 0.0001) {
					mean = moment1 / total_weight;
					deviation = sqrt(max(moment2 / total_weight - mean * mean, vec3(0.0)));
					// mirror rays are not stochastic, only blur the rough ones
					filtered = mix(current, accum / total_weight, smoothstep(0.02, 0.15, roughness));
				}

				vec4 result = filtered;

				if (ssr_data.history_tex != -1) {
					vec4 prev_view_pos = ssr_data.prev_view * vec4(world_pos, 1.0);
					vec4 prev_clip = ssr_data.prev_projection * prev_view_pos;

					if (prev_clip.w > 1e-5) {
						vec2 prev_uv = prev_clip.xy / prev_clip.w * 0.5 + 0.5;

						if (prev_uv.x > 0.0 && prev_uv.x < 1.0 && prev_uv.y > 0.0 && prev_uv.y < 1.0) {
							float prev_depth = -prev_view_pos.z;
							float history_depth = texture(TEXTURE(ssr_data.history_depth_tex), prev_uv).r;

							if (abs(history_depth - prev_depth) < prev_depth * 0.05 + 0.02) {
								vec4 history = texture(TEXTURE(ssr_data.history_tex), prev_uv);

								if (!any(isnan(history))) {
									vec3 clamp_extent = deviation * 1.5 + mean * 0.05 + 0.001;
									history.rgb = clamp(history.rgb, mean - clamp_extent, mean + clamp_extent);
									float history_weight = mix(0.8, 0.94, smoothstep(0.0, 0.3, roughness));
									result = mix(filtered, history, history_weight);
								}
							}
						}
					}
				}

				imageStore(out_ssr, pos, result);
				imageStore(out_ssr_depth, pos, vec4(view_depth));
			}
		]],
	},
}
