local assets = import("goluwa/assets.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local screen_reconstruct = import("goluwa/render3d/screen_reconstruct.lua")
local system = import("goluwa/system.lua")
local compute_helpers = import("goluwa/render3d/compute_helpers.lua")
local COMPUTE_LOCAL_SIZE = {x = 8, y = 8, z = 1}
local TILE_WIDTH = COMPUTE_LOCAL_SIZE.x + 2
local TILE_HEIGHT = COMPUTE_LOCAL_SIZE.y + 2
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
					{"blue_noise_tex", "int"},
					{"prev_view", "mat4"},
					{"prev_projection", "mat4"},
				},
				write = function(self, block)
					render3d.WriteCameraBlock(self, block)
					render3d.WriteGBufferBlock(self, block)
					render3d.WriteLastFrameBlock(self, block)
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
			#define SSR_SPATIAL_DEPTH_WEIGHT 48.0
			#define SSR_SPATIAL_NORMAL_POWER 32.0
			#define SSR_ROUGH_REFLECTION_THRESHOLD 0.08
			#define SSR_ROUGH_MULTI_SAMPLES 3
			#define SSR_TILE_WIDTH ]] .. tostring(TILE_WIDTH) .. "\n" .. [[
			#define SSR_TILE_HEIGHT ]] .. tostring(TILE_HEIGHT) .. "\n" .. [[
			#define PI 3.14159265359

			shared vec4 ssr_tile[SSR_TILE_HEIGHT][SSR_TILE_WIDTH];

			float saturate(float x) {
				return clamp(x, 0.0, 1.0);
			}

			float luminance(vec3 color) {
				return dot(color, vec3(0.2126, 0.7152, 0.0722));
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

			vec2 blue_noise(ivec2 pixel) {
				ivec2 noise_size = textureSize(TEXTURE(ssr_data.blue_noise_tex), 0);
				return texelFetch(TEXTURE(ssr_data.blue_noise_tex), pixel % noise_size, 0).rg;
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

			vec3 clamp_reflection_fireflies(vec2 uv, vec3 hit_color, float mip_level, float roughness) {
				if (roughness <= 0.02) {
					return hit_color;
				}

				vec2 texel = 1.0 / vec2(textureSize(TEXTURE(ssr_data.last_frame_tex), 0));
				vec2 radius = texel * (1.0 + roughness * 6.0);
				vec3 neighborhood = textureLod(TEXTURE(ssr_data.last_frame_tex), clamp(uv + vec2(radius.x, 0.0), vec2(0.001), vec2(0.999)), mip_level).rgb;
				neighborhood += textureLod(TEXTURE(ssr_data.last_frame_tex), clamp(uv + vec2(-radius.x, 0.0), vec2(0.001), vec2(0.999)), mip_level).rgb;
				neighborhood += textureLod(TEXTURE(ssr_data.last_frame_tex), clamp(uv + vec2(0.0, radius.y), vec2(0.001), vec2(0.999)), mip_level).rgb;
				neighborhood += textureLod(TEXTURE(ssr_data.last_frame_tex), clamp(uv + vec2(0.0, -radius.y), vec2(0.001), vec2(0.999)), mip_level).rgb;
				neighborhood *= 0.25;

				float neighborhood_luma = luminance(neighborhood);
				float hit_luma = luminance(hit_color);
				float clamp_scale = saturate((roughness - 0.02) * 3.0);
				float allowed_luma = max(neighborhood_luma * mix(6.0, 2.0, clamp_scale), neighborhood_luma + 0.02);

				if (hit_luma <= allowed_luma || hit_luma <= 1e-5) {
					return hit_color;
				}

				return hit_color * (allowed_luma / hit_luma);
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

			vec2 get_ssr_rough_sample_xi(vec2 xi, int index) {
				if (index == 0) return xi;
				if (index == 1) return fract(xi + vec2(0.5, 0.33333334));
				return fract(xi + vec2(0.25, 0.6666667));
			}

			vec4 trace_ssr_direction(vec4 pos_vs, vec3 R_vs, float roughness, float jitter_seed) {
				if (dot(R_vs, R_vs) <= 1e-5) return vec4(0.0);

				float jitter = mix(0.9, 1.1, jitter_seed);
				float step_size = 0.08 * jitter;
				vec3 current_pos = pos_vs.xyz + R_vs * step_size;
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

							vec2 last_frame_uv = get_last_frame_uv(end);

							if (last_frame_uv.x <= 0.0 || last_frame_uv.x >= 1.0 || last_frame_uv.y <= 0.0 || last_frame_uv.y >= 1.0) {
								return vec4(0.0);
							}

							vec3 hit_color;
							float dist = length(current_pos - pos_vs.xyz);
							float mip_level = 0.0;

							if (roughness > 0.1) {
								vec2 tex_size = vec2(textureSize(TEXTURE(ssr_data.last_frame_tex), 0));
								float cone = roughness * dist * 0.05;
								float mip = log2(max(1.0, cone * max(tex_size.x, tex_size.y)));
								mip_level = min(mip + 0.75, 5.0);
								hit_color = textureLod(TEXTURE(ssr_data.last_frame_tex), last_frame_uv, mip_level).rgb;
							} else {
								hit_color = texture(TEXTURE(ssr_data.last_frame_tex), last_frame_uv).rgb;
							}

							hit_color = clamp_reflection_fireflies(last_frame_uv, hit_color, mip_level, roughness);

							float edge_fade = 1.0 - pow(max(abs(uv.x - 0.5), abs(uv.y - 0.5)) * 2.0, 3.0);
							edge_fade *= 1.0 - pow(max(abs(last_frame_uv.x - 0.5), abs(last_frame_uv.y - 0.5)) * 2.0, 3.0);
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

			vec4 cast_ssr_ray(vec3 world_pos, vec3 N, vec3 V, float roughness, vec2 xi) {
				if (ssr_data.last_frame_tex == -1) return vec4(0.0);
				if (roughness > SSR_ROUGHNESS_CUTOFF) return vec4(0.0);

				vec3 N_vs = normalize(mat3(ssr_data.view) * N);
				vec3 V_vs = normalize(mat3(ssr_data.view) * V);
				vec4 pos_vs = ssr_data.view * vec4(world_pos, 1.0);

				vec3 T;
				vec3 B;
				buildOrthonormalBasis(N_vs, T, B);

				vec3 mirror_R_vs = reflect(-V_vs, N_vs);

				if (dot(N_vs, mirror_R_vs) < 0.0) return vec4(0.0);

				if (roughness <= SSR_ROUGH_REFLECTION_THRESHOLD) {
					return trace_ssr_direction(pos_vs, mirror_R_vs, roughness, xi.x);
				}

				vec3 V_local = vec3(dot(V_vs, T), dot(V_vs, B), dot(V_vs, N_vs));
				float alpha = max(0.001, roughness * roughness);
				float rough_mix = saturate((roughness - SSR_ROUGH_REFLECTION_THRESHOLD) * 2.0);
				vec3 color_accum = vec3(0.0);
				float color_weight = 0.0;
				float confidence_accum = 0.0;

				for (int sample_index = 0; sample_index < SSR_ROUGH_MULTI_SAMPLES; sample_index++) {
					vec2 sample_xi = get_ssr_rough_sample_xi(xi, sample_index);
					vec3 H_local = sampleGGXVNDF(V_local, alpha, sample_xi);
					vec3 H_vs = normalize(T * H_local.x + B * H_local.y + N_vs * H_local.z);
					vec3 sample_R_vs = normalize(mix(mirror_R_vs, reflect(-V_vs, H_vs), rough_mix));

					if (dot(N_vs, sample_R_vs) < 0.0) {
						continue;
					}

					vec4 sample_hit = trace_ssr_direction(pos_vs, sample_R_vs, roughness, sample_xi.x);
					float sample_weight = max(sample_hit.a, 0.0) + 0.0001;
					color_accum += sample_hit.rgb * sample_weight;
					color_weight += sample_weight;
					confidence_accum += sample_hit.a;
				}

				if (color_weight <= 0.0001) {
					return vec4(0.0);
				}

				return vec4(color_accum / color_weight, confidence_accum / float(SSR_ROUGH_MULTI_SAMPLES));
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
				vec2 xi = blue_noise(clamped_pos);
				return cast_ssr_ray(world_pos, N, V, roughness, xi);
			}

			void write_tile_sample(ivec2 tile_pos, ivec2 sample_pos, ivec2 size) {
				ssr_tile[tile_pos.y][tile_pos.x] = compute_current_ssr(sample_pos, size);
			}

			vec4 resolve_current_ssr(ivec2 pos, ivec2 size, ivec2 local_pos, vec4 current) {
				vec2 uv = get_screen_uv(pos, size);
				float depth = get_depth(uv);

				if (depth == 1.0) {
					return current;
				}

				vec3 center_normal = get_normal(uv);
				float center_roughness = get_roughness(uv);
				vec4 accum = vec4(0.0);
				float total_weight = 0.0;

				for (int y = -1; y <= 1; y++) {
					for (int x = -1; x <= 1; x++) {
						ivec2 sample_pos = clamp(pos + ivec2(x, y), ivec2(0), size - ivec2(1));
						vec2 sample_uv = get_screen_uv(sample_pos, size);
						float sample_depth = get_depth(sample_uv);

						if (sample_depth == 1.0) {
							continue;
						}

						vec4 sample_value = ssr_tile[local_pos.y + 1 + y][local_pos.x + 1 + x];

						if (sample_value.a <= 0.0001) {
							continue;
						}

						vec3 sample_normal = get_normal(sample_uv);
						float sample_roughness = get_roughness(sample_uv);
						float depth_weight = exp(-abs(sample_depth - depth) * SSR_SPATIAL_DEPTH_WEIGHT);
						float normal_weight = pow(max(dot(center_normal, sample_normal), 0.0), SSR_SPATIAL_NORMAL_POWER);
						float roughness_weight = 1.0 - saturate(abs(sample_roughness - center_roughness) * 6.0);
						float kernel_weight = (x == 0 && y == 0) ? 4.0 : ((x == 0 || y == 0) ? 2.0 : 1.0);
						float weight = kernel_weight * depth_weight * normal_weight * roughness_weight * sample_value.a;

						if (weight <= 0.0001) {
							continue;
						}

						accum += vec4(sample_value.rgb * weight, sample_value.a * weight);
						total_weight += weight;
					}
				}

				if (total_weight <= 0.0001) {
					return current;
				}

				vec4 filtered = accum / total_weight;
				float confidence = max(current.a, filtered.a);
				return vec4(filtered.rgb, confidence);
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
