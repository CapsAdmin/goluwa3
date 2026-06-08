local assets = import("goluwa/assets.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local screen_reconstruct = import("goluwa/render3d/screen_reconstruct.lua")
local system = import("goluwa/system.lua")
local compute_helpers = import("goluwa/render3d/compute_helpers.lua")
local ibl = import("goluwa/render3d/ibl.lua")
local COMPUTE_LOCAL_SIZE = {x = 8, y = 8, z = 1}
local TILE_WIDTH = COMPUTE_LOCAL_SIZE.x + 2
local TILE_HEIGHT = COMPUTE_LOCAL_SIZE.y + 2
local passes = {
	{
		name = "ssgi",
		ComputePass = true,
		ColorFormat = {{"r16g16b16a16_sfloat", {"ssgi", "rgba"}}},
		framebuffer_count = 3,
		LocalSize = COMPUTE_LOCAL_SIZE,
		storage_images = {
			{
				binding_index = 0,
				attachment = 1,
				dst_stage = "fragment",
			},
		},
		uniform_buffers = {
			{
				name = "ssgi_data",
				binding_index = 3,
				block = {
					render3d.camera_block,
					render3d.debug_block,
					render3d.gbuffer_block,
					render3d.last_frame_block,
					{"env_tex", "int"},
					{"brdf_lut_tex", "int"},
					{"ssgi_max_steps", "int"},
					{"ssgi_step_size", "float"},
					{"ssgi_max_distance", "float"},
					{"ssgi_max_mip", "int"},
					{"ssgi_ray_offset", "float"},
					{"ssgi_rough_cutoff", "float"},
					{"ssgi_rough_samples", "int"},
					{"ssgi_samples", "int"},
					{"ssgi_strength", "float"},
					{"lighting_direct_tex", "int"},
				},
				write = function(self, block)
					render3d.WriteCameraBlock(self, block)
					render3d.WriteDebugBlock(self, block)
					render3d.WriteGBufferBlock(self, block)
					render3d.WriteLastFrameBlock(self, block)
					-- Direct lighting texture for GI (optional, set when lighting_direct pass is enabled)
					block.lighting_direct_tex = self:GetTextureIndex(render3d.pipelines.gbuffer:GetFramebuffer():GetAttachment(1))
					block.env_tex = self:GetTextureIndex(render3d.GetEnvironmentTexture())
					block.brdf_lut_tex = self:GetTextureIndex(assets.GetTexture("textures/render/brdf_lut.lua"))
					block.ssgi_max_steps = 32
					block.ssgi_step_size = 0.3
					block.ssgi_max_distance = 50.0
					block.ssgi_max_mip = 5
					block.ssgi_ray_offset = 0.01
					block.ssgi_rough_cutoff = 0.1
					block.ssgi_rough_samples = 12
					block.ssgi_samples = 6
					block.ssgi_strength = 5
					return block
				end,
			},
		},
		custom_declarations = [[
			layout(set = 0, binding = 0, rgba16f) uniform writeonly image2D out_ssgi;
		]],
		shader = [[
		]] .. compute_helpers.GetScreenHelpersGLSL() .. [[
		]] .. ibl.GetBRDFGLSLCode() .. [[
		]] .. ibl.GetEnvironmentGLSLCode() .. [[
		]] .. screen_reconstruct.GetWorldPosFromUVGLSL("ssgi_data") .. [[

			#define SSGI_TILE_WIDTH ]] .. tostring(TILE_WIDTH) .. "\n" .. [[
			#define SSGI_TILE_HEIGHT ]] .. tostring(TILE_HEIGHT) .. "\n" .. [[

			shared vec4 ssgi_tile[SSGI_TILE_HEIGHT][SSGI_TILE_WIDTH];

			float luminance(vec3 color) {
				return dot(color, vec3(0.2126, 0.7152, 0.0722));
			}

			vec2 get_clamped_screen_uv(ivec2 pos, ivec2 size) {
				ivec2 clamped = clamp(pos, ivec2(0), size - ivec2(1));
				return get_screen_uv(clamped, size);
			}

			float get_depth(vec2 uv) {
				return texture(TEXTURE(ssgi_data.depth_tex), uv).r;
			}

			vec3 get_normal(vec2 uv) {
				return texture(TEXTURE(ssgi_data.normal_tex), uv).xyz;
			}

			float get_roughness(vec2 uv) {
				return texture(TEXTURE(ssgi_data.mra_tex), uv).g;
			}

			vec3 get_albedo(vec2 uv) {
				return texture(TEXTURE(ssgi_data.albedo_tex), uv).rgb;
			}

			vec3 get_lighting_direct_color(vec2 uv) {
				return texture(TEXTURE(ssgi_data.lighting_direct_tex), uv).rgb;
			}

			uint hash(uint n) {
				n ^= n >> 16u;
				n *= 0x85ebca6bu;
				n ^= n >> 13u;
				n *= 0xc2b2ae35u;
				n ^= n >> 16u;
				return n;
			}

			vec2 hash2(uint n) {
				uint h = hash(n);
				return vec2(
					float(h & 0x0000FFFFu) / 65535.0,
					float((h >> 16u) & 0x0000FFFFu) / 65535.0
				);
			}

			vec4 cast_ssgi_ray(vec3 world_pos, vec3 N, vec3 V_ws, float roughness, vec2 xi) {
				float max_dist = ssgi_data.ssgi_max_distance;
				int max_steps = ssgi_data.ssgi_max_steps;
				float step_size = ssgi_data.ssgi_step_size;

				vec4 pos_vs = ssgi_data.view * vec4(world_pos, 1.0);
				vec3 pos_ws = world_pos;
				vec3 N_vs = normalize(mat3(ssgi_data.view) * N);
				vec3 V_ws_normalized = normalize(V_ws);

				// Build tangent space in view space (like SSR)
				vec3 T, B;
				if (abs(N_vs.z) > 0.999) {
					T = vec3(1.0, 0.0, 0.0);
					B = vec3(0.0, 1.0, 0.0);
				} else {
					float a = 1.0 / (1.0 + N_vs.z);
					B = vec3(1.0 - N_vs.x * N_vs.x * a, -N_vs.x * N_vs.y * a, -N_vs.x);
					T = normalize(cross(N_vs, B));
				}

				// Cosine-weighted hemisphere sampling (for roughness)
				float alpha = roughness * roughness;
				float phi = 6.2831853 * xi.x;
				float cosTheta = pow(1.0 - xi.y, 1.0 / (1.0 + alpha));
				float sinTheta = sqrt(max(1.0 - cosTheta * cosTheta, 0.0));

				vec3 H_local = vec3(cos(phi) * sinTheta, sin(phi) * sinTheta, cosTheta);
				vec3 dir_vs = normalize(T * H_local.x + B * H_local.y + N_vs * H_local.z);

				// Only trace if direction points into hemisphere
				if (dot(dir_vs, N_vs) < 0.01) {
					return vec4(0.0, 0.0, 0.0, 0.0);
				}

				vec3 ray_origin_vs = pos_vs.xyz + dir_vs * ssgi_data.ssgi_ray_offset;
				vec3 current_pos = ray_origin_vs;

				// Accumulators (TurboGI style)
				vec3 acc = vec3(0.0);
				vec2 maxDot = vec2(-1.0, -1.0); // [max viewing angle, min shadow angle]

				for (int i = 0; i < max_steps; i++) {
					current_pos += dir_vs * step_size;
					float dist = length(current_pos - ray_origin_vs);
					if (dist > max_dist) break;

					vec4 proj = ssgi_data.projection * vec4(current_pos, 1.0);
					proj.xyz /= proj.w;
					vec2 uv = proj.xy * 0.5 + 0.5;

					if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) break;

					// Progressive mipmap traversal
					float ji = dist / max_dist;
					int lod = int(float(ssgi_data.ssgi_max_mip) * ji);
					lod = min(max(lod, 0), ssgi_data.ssgi_max_mip);

					ivec2 depth_size = textureSize(TEXTURE(ssgi_data.depth_tex), 0);
					ivec2 depth_texel = ivec2(uv * vec2(depth_size)) >> lod;
					float sampled_depth = texelFetch(TEXTURE(ssgi_data.depth_tex), depth_texel, lod).r;
					if (sampled_depth >= 1.0) {
						step_size *= 1.05;
						continue;
					}

					vec4 sampled_clip = vec4(uv * 2.0 - 1.0, sampled_depth, 1.0);
					vec4 sampled_view = ssgi_data.inv_projection * sampled_clip;
					sampled_view /= sampled_view.w;

					if (current_pos.z < sampled_view.z) {
						float depth_diff = abs(current_pos.z - sampled_view.z);
						float thickness = 0.5 + step_size * 2.0;
						thickness *= 1.0 + dist * 0.005;

						if (depth_diff < thickness) {
							// Binary search for precise hit
							vec3 start = current_pos - dir_vs * step_size;
							vec3 end = current_pos;
							vec2 best_uv = uv;

							for (int j = 0; j < 8; j++) {
								vec3 mid = mix(start, end, 0.5);
								vec4 mid_proj = ssgi_data.projection * vec4(mid, 1.0);
								mid_proj.xyz /= mid_proj.w;
								vec2 mid_uv = mid_proj.xy * 0.5 + 0.5;
								ivec2 depth_size = textureSize(TEXTURE(ssgi_data.depth_tex), 0);
								float mid_depth = texelFetch(TEXTURE(ssgi_data.depth_tex), ivec2(mid_uv * vec2(depth_size)), 0).r;
								vec4 mid_clip = vec4(mid_uv * 2.0 - 1.0, mid_depth, 1.0);
								vec4 mid_view = ssgi_data.inv_projection * mid_clip;
								mid_view /= mid_view.w;

								if (mid.z < mid_view.z) {
									end = mid;
									best_uv = mid_uv;
								} else {
									start = mid;
								}
							}

							// Get hit surface properties
							ivec2 normal_size = textureSize(TEXTURE(ssgi_data.normal_tex), 0);
							vec3 hit_normal_ws = texelFetch(TEXTURE(ssgi_data.normal_tex), ivec2(best_uv * vec2(normal_size)) >> lod, lod).xyz;
							vec3 surfN_ws = get_normal(best_uv);
							vec3 hit_pos_ws = get_world_pos(best_uv, get_depth(best_uv));

							// Direction from hit point to surface
							vec3 sV_ws = normalize(pos_ws - hit_pos_ws);

							// Angle-based shadowing (TurboGI maxDot tracking)
							float vDot = dot(normalize(pos_vs.xyz / pos_vs.w), normalize(sampled_view.xyz / sampled_view.w));
							float att2 = 1.0 / (1.0 + 0.1 * dot(current_pos - ray_origin_vs, current_pos - ray_origin_vs) / (1.0 + 0.05 * length(pos_vs.xyz)));

							if (vDot > maxDot.x) {
								maxDot.x = maxDot.x + (vDot - maxDot.x) * att2;
							}

							float sh = 0.0;
							if (vDot >= maxDot.y) {
								sh = vDot - maxDot.y;
								maxDot.y = maxDot.y + (vDot - maxDot.y) * (0.75 + 0.25 * att2);
							}

							// Upward-facing transfer function (TurboGI style)
							// Only count surfaces facing away from center (floors/ceilings)
							float trns = saturate(dot(surfN_ws, sV_ws)) * ceil(dot(hit_normal_ws, sV_ws));

							// Two-term distance attenuation (TurboGI style)
							float z_atten = 1.0 / (1.0 + 0.5 * dot(hit_pos_ws.z - pos_ws.z, hit_pos_ws.z - pos_ws.z) / (1.0 + 0.05 * length(pos_vs.xyz)));
							float dist_atten = 1.0 / (1.0 + 0.1 * dot(hit_pos_ws - pos_ws, hit_pos_ws - pos_ws) / (1.0 + 0.05 * length(pos_vs.xyz)));
							float dist_atten_combined = z_atten * dist_atten;

							// Accumulate lighting
							vec3 hit_color = get_lighting_direct_color(best_uv) + get_albedo(best_uv) * 0.5; // Add some albedo-based color to help with dark materials
							vec3 irradiance = sample_environment_irradiance(ssgi_data.env_tex, hit_normal_ws);
							acc += sh * hit_color * irradiance * 3.0 * dist_atten_combined * trns;
						}
					}
					step_size *= 1.05;
				}

				// Compute confidence from accumulated hits
				float confidence = 0.0;
				if (maxDot.y > -0.5) {
					confidence = maxDot.y;
				}

				return vec4(acc, confidence);
			}

			void write_tile_sample(ivec2 tile_pos, ivec2 sample_pos, ivec2 size) {
				vec2 uv = get_clamped_screen_uv(sample_pos, size);
				float depth = get_depth(uv);

				if (depth >= 1.0) {
					ssgi_tile[tile_pos.y][tile_pos.x] = vec4(0.0);
					return;
				}

				vec3 N = get_normal(uv);
				float roughness = get_roughness(uv);
				vec3 world_pos = get_world_pos(uv, depth);
				vec3 V_ws = normalize(ssgi_data.camera_position.xyz - world_pos);

				// Multi-sample: trace multiple rays per pixel using hash-based random
				vec3 accum = vec3(0.0);
				float conf_accum = 0.0;
				int num_samples = ssgi_data.ssgi_samples;
				uint pixel_seed = uint(get_screen_pos().x * 374761393u + get_screen_pos().y * 668265263u);
				for (int s = 0; s < 8; s++) {
					if (s >= num_samples) break;
					vec2 xi = hash2(pixel_seed + uint(s) * 73856093u);
					vec4 ray_sample = cast_ssgi_ray(world_pos, N, V_ws, roughness, xi);
					accum += ray_sample.rgb;
					conf_accum += ray_sample.a;
				}

				ssgi_tile[tile_pos.y][tile_pos.x] = vec4(accum / float(num_samples), conf_accum / float(num_samples));
			}

			vec3 get_ssgi_fallback(vec2 uv, vec3 N) {
				// Fallback to environment irradiance when no ray hit
				vec3 irradiance = sample_environment_irradiance(ssgi_data.env_tex, N);
				vec3 color = get_lighting_direct_color(uv);
				return color * irradiance * (1.0 / 3.14159265);
			}

			void main() {
				ivec2 pos = get_screen_pos();
				ivec2 size = imageSize(out_ssgi);

				if (!is_screen_pos_in_bounds(pos, size)) return;

				ivec2 local_pos = ivec2(gl_LocalInvocationID.xy);
				ivec2 tile_pos = local_pos + ivec2(1);

				// Write center and border samples for spatial filtering
				write_tile_sample(tile_pos, pos, size);

				if (local_pos.x == 0) {
					write_tile_sample(ivec2(0, tile_pos.y), pos + ivec2(-1, 0), size);
				}
				if (local_pos.x == ]] .. tostring(COMPUTE_LOCAL_SIZE.x - 1) .. [[) {
					write_tile_sample(ivec2(SSGI_TILE_WIDTH - 1, tile_pos.y), pos + ivec2(1, 0), size);
				}
				if (local_pos.y == 0) {
					write_tile_sample(ivec2(tile_pos.x, 0), pos + ivec2(0, -1), size);
				}
				if (local_pos.y == ]] .. tostring(COMPUTE_LOCAL_SIZE.y - 1) .. [[) {
					write_tile_sample(ivec2(tile_pos.x, SSGI_TILE_HEIGHT - 1), pos + ivec2(0, 1), size);
				}
				if (local_pos.x == 0 && local_pos.y == 0) {
					write_tile_sample(ivec2(0, 0), pos + ivec2(-1, -1), size);
				}
				if (local_pos.x == ]] .. tostring(COMPUTE_LOCAL_SIZE.x - 1) .. [[ && local_pos.y == 0) {
					write_tile_sample(ivec2(SSGI_TILE_WIDTH - 1, 0), pos + ivec2(1, -1), size);
				}
				if (local_pos.x == 0 && local_pos.y == ]] .. tostring(COMPUTE_LOCAL_SIZE.y - 1) .. [[) {
					write_tile_sample(ivec2(0, SSGI_TILE_HEIGHT - 1), pos + ivec2(-1, 1), size);
				}
				if (local_pos.x == ]] .. tostring(COMPUTE_LOCAL_SIZE.x - 1) .. [[ && local_pos.y == ]] .. tostring(COMPUTE_LOCAL_SIZE.y - 1) .. [[) {
					write_tile_sample(ivec2(SSGI_TILE_WIDTH - 1, SSGI_TILE_HEIGHT - 1), pos + ivec2(1, 1), size);
				}

				memoryBarrierShared();
				barrier();

				// Write raw SSGI result (denoising happens in separate passes)
				imageStore(out_ssgi, pos, ssgi_tile[tile_pos.y][tile_pos.x]);
			}
		]],
	},
}

for i = 1, 2 do
	table.insert(
		passes,
		{
			name = "ssgi_filter_" .. i,
			ComputePass = true,
			ColorFormat = {{"r16g16b16a16_sfloat", {"ssgi_filter_" .. i, "rgba"}}},
			framebuffer_count = 1,
			LocalSize = COMPUTE_LOCAL_SIZE,
			storage_images = {
				{
					binding_index = 0,
					attachment = 1,
					dst_stage = "fragment",
				},
			},
			uniform_buffers = {
				{
					name = "ssgi_data",
					binding_index = 3,
					block = {
						render3d.gbuffer_block,
						{"main_tex", "int"},
					},
					write = function(self, block)
						do
							local idx = frame_index or (system.GetFrameNumber() % 3 + 1)
							local fb

							if i == 1 then
								fb = render3d.pipelines.ssgi
							elseif i > 1 then
								fb = render3d.pipelines["ssgi_filter_" .. (i - 1)]
							end

							block.main_tex = self:GetTextureIndex(fb:GetFramebuffer(idx):GetAttachment(1))
						end

						return block
					end,
				},
			},
			custom_declarations = [[
			layout(set = 0, binding = 0, rgba16f) uniform writeonly image2D out_image;
		]],
			shader = [[
		]] .. compute_helpers.GetScreenHelpersGLSL() .. [[
			#ifndef saturate
			#define saturate(x) clamp(x, 0.0, 1.0)
			#endif

			float get_depth(vec2 uv) {
				return texture(TEXTURE(ssgi_data.depth_tex), uv).r;
			}

			vec3 get_normal(vec2 uv) {
				return texture(TEXTURE(ssgi_data.normal_tex), uv).xyz;
			}

			// 5-tap cross pattern (TurboGI style)
			const ivec2 ioff[5] = {
				ivec2( 0,-1),
				ivec2(-1, 0), ivec2( 0, 0), ivec2( 1, 0),
				ivec2( 0, 1)
			};

			void main() {
				ivec2 pos = get_screen_pos();
				ivec2 size = imageSize(out_image);
				if (!is_screen_pos_in_bounds(pos, size)) return;

				vec2 uv = get_screen_uv(pos, size);
				vec4 current = texture(TEXTURE(ssgi_data.main_tex), uv);
				float cenD = get_depth(uv);
				vec3 cenN = get_normal(uv);

				vec4 shLum = vec4(0.0);
				vec4 shCol = vec4(0.0);
				float accw = 0.0;

				for (int i = 0; i < 5; i++) {
					vec2 nxy = uv + vec2(float(ioff[i].x), float(ioff[i].y)) / vec2(size);

					vec4 samC = texture(TEXTURE(ssgi_data.main_tex), nxy);
					float samD = get_depth(nxy);
					vec3 samN = get_normal(nxy);

					// Normal-based weighting (TurboGI: w *= w squared)
					float nW = saturate(dot(cenN, samN));
					nW *= nW;

					// Depth-based weighting
					float dW = exp(-40.0 * abs(cenD - samD) / (cenD + 1e-7)) + 1e-7;

					float w = nW * dW;

					shLum += w * vec4(length(samC.rgb), 0.0, 0.0, 1.0);
					shCol += w * samC / (length(samC.rgb) + 0.0001);
					accw += w;
				}

				shLum /= accw;
				shCol /= accw;

				vec3 filtered = shCol.rgb * shLum.r;

				// Blend with unfiltered center
				float blend = 0.85;
				imageStore(out_image, pos, vec4(mix(current.rgb, filtered, blend), current.a));
			}
		]],
		}
	)
end

return passes
