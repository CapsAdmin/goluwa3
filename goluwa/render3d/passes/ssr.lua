local assets = import("goluwa/assets.lua")
local ibl = import("goluwa/render3d/ibl.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local gbuffer_layout = import("goluwa/render3d/gbuffer_layout.lua")
local surface_weather = import("goluwa/render3d/surface_weather.lua")
local screen_reconstruct = import("goluwa/render3d/screen_reconstruct.lua")
local system = import("goluwa/system.lua")
local compute_helpers = import("goluwa/render3d/compute_helpers.lua")
local scene_reflection = import("goluwa/render3d/scene_reflection.lua")
local COMPUTE_LOCAL_SIZE = {x = 8, y = 8, z = 1}
local RAY_QUERY = scene_reflection.RAY_QUERY
local REFLECTION_BINDINGS = {scene = 5, triangles = 6, materials = 7, light_grid = 9}
return {
	{
		name = "ssr",
		ComputePass = true,
		ColorFormat = {
			{"r16g16b16a16_sfloat", {"ssr", "rgba"}},
			{"r16_sfloat", {"ssr_depth", "r"}},
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
		descriptor_sets = RAY_QUERY and
			scene_reflection.GetDescriptorSets(REFLECTION_BINDINGS, "compute") or
			nil,
		on_pre_draw = RAY_QUERY and
			function(self, cmd, frame, desc)
				scene_reflection.Bind(self, cmd, desc, REFLECTION_BINDINGS)
			end or
			nil,
		uniform_buffers = {
			{
				name = "ssr_data",
				binding_index = 3,
				block = {
					render3d.camera_block,
					gbuffer_layout.block,
					surface_weather.rain_surface_block,
					render3d.last_frame_block,
					{"blue_noise_tex", "int"},
					{"exposure_tex", "int"},
					{"env_tex", "int"},
					{"history_tex", "int"},
					{"history_depth_tex", "int"},
					{"frame_index", "int"},
					{"prev_view", "mat4"},
					{"prev_projection", "mat4"},
					post_source.pre_exposure_block,
					RAY_QUERY and scene_reflection.block or nil,
				},
				write = function(self, block)
					render3d.WriteCameraBlock(self, block)
					gbuffer_layout.WriteBlock(self, block)
					surface_weather.WriteRainSurfaceBlock(self, block)
					render3d.WriteLastFrameBlock(self, block)
					post_source.WritePreExposureBlock(self, block)
					block.blue_noise_tex = self:GetTextureIndex(assets.GetTexture("textures/render/blue_noise.lua"))
					block.env_tex = self:GetTextureIndex(render3d.GetEnvironmentTexture())
					local exposure = post_source.GetExposureTexture(true)
					block.exposure_tex = exposure and self:GetTextureIndex(exposure) or -1
					local frame = system.GetFrameNumber()
					block.frame_index = frame

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

					if RAY_QUERY then scene_reflection.WriteBlock(self, block) end

					local prev_view = render3d.GetPreviousViewMatrix()
					local prev_projection = render3d.GetPreviousProjectionMatrix()

					if prev_view then
						prev_view:CopyToFloatPointer(block.prev_view)
					else
						render3d.GetCamera():BuildViewMatrix():CopyToFloatPointer(block.prev_view)
					end

					if prev_projection then
						prev_projection:CopyToFloatPointer(block.prev_projection)
					else
						render3d.GetCamera():BuildProjectionMatrix():CopyToFloatPointer(block.prev_projection)
					end

					return block
				end,
			},
			RAY_QUERY and scene_reflection.GetDDGIUniformBuffer(8) or nil,
		},
		custom_declarations = [[
			layout(set = 0, binding = 0, rgba16f) uniform writeonly image2D out_ssr;
			layout(set = 0, binding = 1, r16f) uniform writeonly image2D out_ssr_depth;
		]] .. (
				RAY_QUERY and
				scene_reflection.GetDeclarationGLSL(REFLECTION_BINDINGS) or
				""
			),
		shader = [[
		]] .. render3d.GetEmissiveGLSL() .. compute_helpers.GetScreenHelpersGLSL() .. gbuffer_layout.GetDecodeGLSL("ssr_data") .. surface_weather.GetRainSurfaceGLSL("ssr_data") .. [[
		]] .. ibl.GetBRDFGLSLCode() .. [[
		]] .. ibl.GetEnvironmentGLSLCode() .. (
				RAY_QUERY and
				scene_reflection.GetGLSL("ssr_data") or
				""
			) .. [[
		]] .. screen_reconstruct.GetWorldPosFromUVGLSL("ssr_data") .. [[
		]] .. screen_reconstruct.GetGeometricNormalGLSL("ssr_data", {world_pos_function = "get_world_pos"}) .. [[
			#define SSR_MAX_STEPS 48
]] .. post_source.GetPreExposureGLSL("ssr_data") .. [[
			#define SSR_BINARY_STEPS 6
			#define SSR_STRIDE 2.0
			#define SSR_MAX_DISTANCE 80.0
			// where lighting stops using ssr (get_ssr_blend_weight)
			#define SSR_ROUGHNESS_CUTOFF 0.45
			#define SSR_MIRROR_THRESHOLD 0.06
			// times white on screen, under last frame's exposure
			#define SSR_MAX_HIT_LUMINANCE 8.0
			#define SSR_SPATIAL_NORMAL_POWER 32.0
			#define SSR_TILE_WIDTH ]] .. tostring(COMPUTE_LOCAL_SIZE.x) .. "\n" .. [[
			#define SSR_TILE_HEIGHT ]] .. tostring(COMPUTE_LOCAL_SIZE.y) .. [[

			shared vec4 ssr_tile[SSR_TILE_HEIGHT][SSR_TILE_WIDTH];
			shared float ssr_tile_depth[SSR_TILE_HEIGHT][SSR_TILE_WIDTH];
			shared vec3 ssr_tile_normal[SSR_TILE_HEIGHT][SSR_TILE_WIDTH];

			ivec2 ssr_size;
			ivec2 gbuffer_size;
			vec2 gbuffer_ratio;
			vec4 inv_projection_row_z;
			vec4 inv_projection_row_w;
			float max_hit_luminance;

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
				return gbuffer_depth(clamp(ivec2(uv * vec2(gbuffer_size)), ivec2(0), gbuffer_size - 1));
			}

			bool fetch_surface_motion(vec2 uv, out vec2 prev_uv, out float prev_depth) {
				if (ssr_data.velocity_tex != -1) {
					vec3 motion = texture(TEXTURE(ssr_data.velocity_tex), uv).rgb;
					prev_uv = uv - motion.xy;
					prev_depth = motion.z;
					return prev_depth > 1e-5;
				}

				vec3 world_pos = get_world_pos(uv, fetch_depth(uv));
				vec4 prev_view_pos = ssr_data.prev_view * vec4(world_pos, 1.0);
				vec4 prev_clip = ssr_data.prev_projection * prev_view_pos;

				if (prev_clip.w <= 1e-5) return false;

				prev_uv = prev_clip.xy / prev_clip.w * 0.5 + 0.5;
				prev_depth = -prev_view_pos.z;
				return true;
			}

			vec2 blue_noise(ivec2 pixel) {
				ivec2 noise_size = textureSize(TEXTURE(ssr_data.blue_noise_tex), 0);
				vec2 xi = texelFetch(TEXTURE(ssr_data.blue_noise_tex), pixel % noise_size, 0).rg;
				return fract(xi + float(ssr_data.frame_index % 64) * vec2(0.7548776662, 0.5698402910));
			}

			void buildOrthonormalBasis(vec3 n, out vec3 t, out vec3 b) {
				float a = 1.0 / (1.0 + n.z);
				float d = -n.x * n.y * a;
				t = vec3(1.0 - n.x * n.x * a, d, -n.x);
				b = vec3(d, 1.0 - n.y * n.y * a, -n.y);
			}

			vec2 get_last_frame_uv(vec2 hit_uv, vec3 hit_view_pos) {
				if (ssr_data.velocity_tex != -1) {
					return hit_uv - texture(TEXTURE(ssr_data.velocity_tex), hit_uv).xy;
				}

				vec4 world_hit = ssr_data.inv_view * vec4(hit_view_pos, 1.0);
				vec4 prev_clip = ssr_data.prev_projection * (ssr_data.prev_view * vec4(world_hit.xyz, 1.0));

				if (abs(prev_clip.w) <= 1e-5) {
					return vec2(-1.0);
				}

				prev_clip /= prev_clip.w;
				return prev_clip.xy * 0.5 + 0.5;
			}

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

								vec3 hit_normal_vs = mat3(ssr_data.view) * gbuffer_normal(uv);

								if (dot(hit_normal_vs, R_vs) > 0.0) {
									t_prev = t;
									z_prev = z_ray;
									continue;
								}

								vec3 hit_vs = get_view_pos(uv, depth);
								vec2 last_frame_uv = get_last_frame_uv(uv, hit_vs);

								if (last_frame_uv.x <= 0.0 || last_frame_uv.x >= 1.0 || last_frame_uv.y <= 0.0 || last_frame_uv.y >= 1.0) {
									return vec4(0.0);
								}

								float edge_fade = 1.0 - pow(max(abs(uv.x - 0.5), abs(uv.y - 0.5)) * 2.0, 3.0);
								edge_fade *= 1.0 - pow(max(abs(last_frame_uv.x - 0.5), abs(last_frame_uv.y - 0.5)) * 2.0, 3.0);
								float dist_fade = 1.0 - smoothstep(SSR_MAX_DISTANCE * 0.7, SSR_MAX_DISTANCE, length(hit_vs - pos_vs));
								float thick_conf = 1.0 - saturate(refined_diff / max(0.15, -z_surf * 0.03));
								// last frame's scene was pre-exposed for last frame, reflections are absolute
								vec3 hit_color = texture(TEXTURE(ssr_data.last_frame_tex), last_frame_uv).rgb / get_previous_pre_exposure();

								if (roughness > SSR_MIRROR_THRESHOLD) {
									float hit_luma = luminance(hit_color);

									if (hit_luma > max_hit_luminance) hit_color *= max_hit_luminance / hit_luma;
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

			vec4 cast_ssr_ray(vec3 world_pos, vec3 pos_vs, vec3 N, vec3 geometric_N, vec3 V, float roughness, vec2 xi) {
				if (ssr_data.last_frame_tex == -1) return vec4(0.0);
				if (roughness > SSR_ROUGHNESS_CUTOFF) return vec4(0.0);

				// a normal map can turn a pixel away from the camera, which would
				// reflect into the surface. bend it back toward the viewer
				N = bend_normal_to_view(N, V);
				vec3 N_vs = normalize(mat3(ssr_data.view) * N);
				vec3 V_vs = normalize(-pos_vs);
				vec3 mirror_R_vs = reflect(-V_vs, N_vs);

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

				// a normal map tilted sideways can reflect below the actual surface,
				// where the ray would leave through the floor and find the sky.
				// mirror it back above the geometric plane instead
				vec3 geometric_N_vs = mat3(ssr_data.view) * geometric_N;
				float below = dot(R_vs, geometric_N_vs);

				if (below < 0.01) R_vs = normalize(R_vs + geometric_N_vs * (0.01 - 2.0 * below));

				vec4 hit = trace_ssr_direction(pos_vs, R_vs, roughness, xi.y);
				vec3 R_world = (ssr_data.inv_view * vec4(R_vs, 0.0)).xyz;

				#ifdef SCENE_REFLECTION
				// what the screen doesn't hold (off screen, behind something or
				// facing the camera) is traced; faded screen hits blend into it
				if (scene_reflection_ready() && hit.a < 0.999) {
					vec3 origin = world_pos + geometric_N * (0.02 + 0.002 * -pos_vs.z);
					float traced_t;
					vec3 traced = trace_scene_reflection(origin, R_world, N, roughness, SCENE_REFLECTION_MAX_DISTANCE, traced_t);

					if (roughness > SSR_MIRROR_THRESHOLD) {
						float traced_luma = luminance(traced);

						if (traced_luma > max_hit_luminance) traced *= max_hit_luminance / traced_luma;
					}

					return vec4(mix(traced, hit.rgb, hit.a), 1.0);
				}
				#endif

				// lighting fills the rest with its sky visibility aware environment
				return hit.a > 0.0 ? hit : vec4(0.0);
			}

			void main() {
				ivec2 pos = get_screen_pos();
				ssr_size = imageSize(out_ssr);
				gbuffer_size = textureSize(TEXTURE(ssr_data.depth_tex), 0);
				gbuffer_ratio = vec2(gbuffer_size) / vec2(ssr_size);
				mat4 inv_projection = ssr_data.inv_projection;
				inv_projection_row_z = vec4(inv_projection[0][2], inv_projection[1][2], inv_projection[2][2], inv_projection[3][2]);
				inv_projection_row_w = vec4(inv_projection[0][3], inv_projection[1][3], inv_projection[2][3], inv_projection[3][3]);
				max_hit_luminance = ssr_data.exposure_tex != -1 ? SSR_MAX_HIT_LUMINANCE / max(texture(TEXTURE(ssr_data.exposure_tex), vec2(0.5)).r, 1e-8) : 1e30;
				ivec2 local_pos = ivec2(gl_LocalInvocationID.xy);
				bool in_bounds = is_screen_pos_in_bounds(pos, ssr_size);
				ivec2 gbuffer_pos = min(ivec2((vec2(pos) + 0.5) * gbuffer_ratio), gbuffer_size - 1);
				vec2 uv = (vec2(gbuffer_pos) + 0.5) / vec2(gbuffer_size);
				float depth = in_bounds ? gbuffer_depth(gbuffer_pos) : 1.0;
				vec4 current = vec4(0.0);
				vec3 N = vec3(0.0, 1.0, 0.0);
				vec3 world_pos = vec3(0.0);
				float roughness = 1.0;
				float view_depth = 0.0;

				if (depth < 1.0) {
					N = gbuffer_normal(gbuffer_pos);
					// the gbuffer stores ggx alpha
					roughness = sqrt(gbuffer_roughness(gbuffer_pos));
					world_pos = get_world_pos(uv, depth);
					vec3 pos_vs = (ssr_data.view * vec4(world_pos, 1.0)).xyz;
					view_depth = -pos_vs.z;
					vec3 V = normalize(ssr_data.camera_position.xyz - world_pos);
					vec3 geometric_N = get_geometric_normal(gbuffer_pos, world_pos, depth, V, N);

					// a clearcoat is smoother than the surface under it, the sharp reflection is its. traced off the
					// flat film: the rain's waves on it are too fine and too quick for the ssr's resolution and
					// history, the lighting pass bends what this finds by them. far away they roughen the film
					if (gbuffer_clearcoat(gbuffer_pos) > 0.5) {
						float coat_alpha = gbuffer_clearcoat_roughness(gbuffer_pos);
						vec3 coat_N = gbuffer_clearcoat_normal(gbuffer_pos);
						vec3 rain_N = coat_N;
						float footprint = view_depth / sqrt(max(abs(dot(geometric_N, V)), 0.01)) * 2.0 * ssr_data.inv_projection[1][1] / float(gbuffer_size.y);
						apply_rain_surface(world_pos, footprint, gbuffer_clearcoat_rain(gbuffer_pos), rain_N, coat_alpha);
						N = coat_N;
						roughness = sqrt(coat_alpha);
					}

					current = cast_ssr_ray(world_pos, pos_vs, N, geometric_N, V, roughness, blue_noise(pos));
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

				vec3 moment1 = vec3(0.0);
				vec3 moment2 = vec3(0.0);
				float alpha_accum = 0.0;
				float color_weight = 0.0;
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
						// rgb only counts as much as the sample found something
						float sample_color_weight = weight * sample_value.a;
						moment1 += sample_value.rgb * sample_color_weight;
						moment2 += sample_value.rgb * sample_value.rgb * sample_color_weight;
						color_weight += sample_color_weight;
						alpha_accum += sample_value.a * weight;
						total_weight += weight;
					}
				}

				vec4 filtered = current;
				vec3 mean = current.rgb;
				vec3 deviation = vec3(0.0);

				if (color_weight > 0.0001) {
					mean = moment1 / color_weight;
					deviation = sqrt(max(moment2 / color_weight - mean * mean, vec3(0.0)));
					filtered = mix(current, vec4(mean, alpha_accum / total_weight), smoothstep(0.02, 0.15, roughness));
				}

				vec4 result = filtered;

				if (ssr_data.history_tex != -1) {
					vec2 prev_uv;
					float prev_depth;
					bool has_motion = fetch_surface_motion(uv, prev_uv, prev_depth);

					if (has_motion) {
						if (prev_uv.x > 0.0 && prev_uv.x < 1.0 && prev_uv.y > 0.0 && prev_uv.y < 1.0) {
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
