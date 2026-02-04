local Vec3 = require("structs.vec3")
local GetBlueNoiseTexture = require("render.textures.blue_noise")
local system = require("system")
local render3d = require("render3d.render3d")
local atmosphere = require("render3d.atmosphere")
local lightprobes = require("render3d.lightprobes")
return {
	{
		name = "lighting",
		color_format = {{"r16g16b16a16_sfloat", {"color", "rgba"}}},
		framebuffer_count = 2,
		fragment = {
			uniform_buffers = {
				{
					name = "lighting_data",
					binding_index = 3,
					block = {
						render3d.camera_block,
						{
							"ssao_kernel",
							"vec3",
							function(self, block, key)
								local kernel = {}

								for i = 1, 64 do
									math.randomseed(i)
									local sample = Vec3(math.random() * 2 - 1, math.random() * 2 - 1, math.random()):Normalize()
									sample = sample * math.random()
									local scale = (i - 1) / 64
									scale = math.lerp(0.1, 1.0, scale * scale)
									sample = sample * scale
									table.insert(kernel, sample)
								end

								return function(self, block, key)
									for i, v in ipairs(kernel) do
										v:CopyToFloatPointer(block[key][i - 1])
									end
								end
							end,
							64,
						},
						{
							"lights",
							{
								{"position", "vec4"},
								{"color", "vec4"},
								{"params", "vec4"},
							},
							function(self, block, key)
								local lights = render3d.GetLights()

								for i = 0, 128 - 1 do
									local data = block[key][i]
									local light = lights[i + 1]

									if light then
										if light.LightType == "directional" or light.LightType == "sun" then
											light.Owner.transform:GetRotation():GetForward():CopyToFloatPointer(data.position)
										else
											light.Owner.transform:GetPosition():CopyToFloatPointer(data.position)
										end

										if light.LightType == "directional" or light.LightType == "sun" then
											data.position[3] = 0
										elseif light.LightType == "point" then
											data.position[3] = 1
										elseif light.LightType == "spot" then
											data.position[3] = 2
										else
											error("Unknown light type: " .. tostring(light.LightType), 2)
										end

										data.color[0] = light.Color.r
										data.color[1] = light.Color.g
										data.color[2] = light.Color.b
										data.color[3] = light.Intensity
										data.params[0] = light.Range
										data.params[1] = light.InnerCone
										data.params[2] = light.OuterCone
										data.params[3] = 0
									else
										data.position[0] = 0
										data.position[1] = 0
										data.position[2] = 0
										data.position[3] = 0
										data.color[0] = 0
										data.color[1] = 0
										data.color[2] = 0
										data.color[3] = 0
										data.params[0] = 0
										data.params[1] = 0
										data.params[2] = 0
										data.params[3] = 0
									end
								end
							end,
							128,
						},
						{
							"light_count",
							"int",
							function(self, block, key)
								block[key] = math.min(#render3d.GetLights(), 128)
							end,
						},
						{
							"shadows",
							{
								{"light_space_matrices", "mat4", 4},
								{"cascade_splits", "int", 4},
								{"shadow_map_indices", "int", 4},
								{"cascade_count", "int"},
							},
							function(self, block, key)
								local sun = nil

								for i, light in ipairs(render3d.GetLights()) do
									if i > 128 then break end

									if
										(
											light.LightType == "sun" or
											light.LightType == "directional"
										)
										and
										light:GetCastShadows()
									then
										sun = light

										break
									end
								end

								if sun then
									local shadow_map = sun:GetShadowMap()
									local cascade_count = shadow_map:GetCascadeCount()

									for i = 1, cascade_count do
										block[key].shadow_map_indices[i - 1] = self:GetTextureIndex(shadow_map:GetDepthTexture(i))
										shadow_map:GetLightSpaceMatrix(i):CopyToFloatPointer(block[key].light_space_matrices[i - 1])
										block[key].cascade_splits[i - 1] = shadow_map:GetCascadeSplits()[i] or -1
									end

									block[key].cascade_count = cascade_count

									-- Fill remaining slots with -1
									for i = cascade_count + 1, 4 do
										block[key].shadow_map_indices[i - 1] = -1
									end
								else
									block[key].cascade_count = 0

									for i = 0, 3 do
										block[key].shadow_map_indices[i] = -1
									end
								end
							end,
						},
						render3d.debug_block,
						render3d.gbuffer_block,
						{
							"env_tex",
							"int",
							function(self, block, key)
								block[key] = self:GetTextureIndex(render3d.GetEnvironmentTexture())
							end,
						},
						{
							"blue_noise_tex",
							"int",
							function(self, block, key)
								block[key] = self:GetTextureIndex(GetBlueNoiseTexture())
							end,
						},
						render3d.last_frame_block,
						render3d.common_block,
						{
							"stars_texture_index",
							"int",
							function(self, block, key)
								block[key] = self:GetTextureIndex(atmosphere.GetStarsTexture())
							end,
						},
						{
							"ssr_tex",
							"int",
							function(self, block, key)
								if
									not render3d.pipelines.ssr_resolve or
									not render3d.pipelines.ssr_resolve.framebuffers
								then
									block[key] = -1
									return
								end

								local current_idx = system.GetFrameNumber() % 2 + 1
								local current_ssr_fb = render3d.pipelines.ssr_resolve:GetFramebuffer(current_idx)
								block[key] = self:GetTextureIndex(current_ssr_fb:GetAttachment(1))
							end,
						},
						{
							"probe_color_textures",
							"int",
							function(self, block, key)
								for i = 0, 63 do
									block[key][i] = -1

									if lightprobes.IsEnabled() then
										local probe = lightprobes.GetProbes()[i + 1]

										if probe and probe.cubemap then
											block[key][i] = self:GetTextureIndex(probe.cubemap)
										end
									end
								end
							end,
							64,
						},
						{
							"probe_depth_textures",
							"int",
							function(self, block, key)
								for i = 0, 63 do
									block[key][i] = -1

									if lightprobes.IsEnabled() then
										local probe = lightprobes.GetProbes()[i + 1]

										if probe and probe.depth_cubemap then
											block[key][i] = self:GetTextureIndex(probe.depth_cubemap)
										end
									end
								end
							end,
							64,
						},
						{
							"probe_positions",
							"vec4",
							function(self, block, key)
								if not lightprobes.IsEnabled() then return end

								for i = 0, 63 do
									local probe = lightprobes.GetProbes()[i + 1]

									if probe then
										block[key][i][0] = probe.position.x
										block[key][i][1] = probe.position.y
										block[key][i][2] = probe.position.z
										block[key][i][3] = probe.radius or 20
									end
								end
							end,
							64,
						},
					},
				},
			},
			shader = [[
			vec3 get_albedo() {
				return texture(TEXTURE(lighting_data.albedo_tex), in_uv).rgb;
			}

			float get_alpha() {
				return texture(TEXTURE(lighting_data.albedo_tex), in_uv).a;
			}

			float get_depth() {
				return texture(TEXTURE(lighting_data.depth_tex), in_uv).r;
			}

			vec3 get_normal() {
				return texture(TEXTURE(lighting_data.normal_tex), in_uv).xyz;
			}

			float get_metallic() {
				vec3 mra = texture(TEXTURE(lighting_data.mra_tex), in_uv).rgb;
				return mra.r;
			}

			float get_roughness() {
				vec3 mra = texture(TEXTURE(lighting_data.mra_tex), in_uv).rgb;
				return mra.g;
			}

			float get_ao() {
				vec3 mra = texture(TEXTURE(lighting_data.mra_tex), in_uv).rgb;
				return mra.b;
			}

			vec3 get_emissive() {
				return texture(TEXTURE(lighting_data.emissive_tex), in_uv).rgb;
			}


			]] .. require("render3d.atmosphere").GetGLSLCode() .. [[


			#define SSR 1
			#define PARALLAX_CORRECTION 1
			#define uv in_uv
			float hash(vec2 p) {
				p = fract(p * vec2(123.34, 456.21));
				p += dot(p, p + 45.32);
				return fract(p.x * p.y);
			}

			vec3 random_vec3(vec2 p) {
				return vec3(hash(p), hash(p + 1.0), hash(p + 2.0)) * 2.0 - 1.0;
			}

			#define saturate(x) clamp(x, 0.0, 1.0)

            float pow5(float x) {
                float x2 = x * x;
                return x2 * x2 * x;
            }

            float D_GGX(float roughness, float NoH) {
                float oneMinusNoHSquared = 1.0 - NoH * NoH;
                float a = NoH * roughness;
                float k = roughness / (oneMinusNoHSquared + a * a);
                float d = k * (k * (1.0 / PI));
                return d;
            }

            float V_SmithGGXCorrelated(float roughness, float NoV, float NoL) {
                float a2 = roughness * roughness;
                float lambdaV = NoL * sqrt((NoV - a2 * NoV) * NoV + a2);
                float lambdaL = NoV * sqrt((NoL - a2 * NoL) * NoL + a2);
                float v = 0.5 / (lambdaV + lambdaL);
                return v;
            }

            vec3 F_Schlick(const vec3 f0, float VoH) {
                float f = pow(1.0 - VoH, 5.0);
                return f + f0 * (1.0 - f);
            }

            vec3 F_SchlickRoughness(vec3 f0, float NdotV, float roughness) {
                float f = pow(1.0 - NdotV, 5.0);
                return f0 + (max(vec3(1.0 - roughness), f0) - f0) * f;
            }

            float Fd_Lambert() {
                return 1.0 / PI;
            }

            // Approximate BRDF integration (Karis/Epic Games approximation)
            vec2 envBRDFApprox(float NdotV, float roughness) {
                vec4 c0 = vec4(-1.0, -0.0275, -0.572, 0.022);
                vec4 c1 = vec4(1.0, 0.0425, 1.04, -0.04);
                vec4 r = roughness * c0 + c1;
                float a004 = min(r.x * r.x, exp2(-9.28 * NdotV)) * r.x + r.y;
                return vec2(-1.04, 1.04) * a004 + r.zw;
            }

			// Cascade debug colors
			const vec3 CASCADE_COLORS[4] = vec3[4](
				vec3(1.0, 0.2, 0.2),  // Red - cascade 1
				vec3(0.2, 1.0, 0.2),  // Green - cascade 2
				vec3(0.2, 0.2, 1.0),  // Blue - cascade 3
				vec3(1.0, 1.0, 0.2)   // Yellow - cascade 4
			);

			float random(vec2 co)
			{
				return fract(sin(dot(co.xy ,vec2(12.9898,78.233))) * 43758.5453);
			}
			vec3 get_noise3_world(vec3 world_pos)
			{
				float x = random(world_pos.xy);
				float y = random(world_pos.yz * x);
				float z = random(world_pos.xz * y);

				return vec3(x, y, z) * 2.0 - 1.0;
			}

			// Get cascade index based on view distance
			int getCascadeIndex(vec3 world_pos) {
				float dist = length(world_pos - lighting_data.camera_position.xyz);
				
				for (int i = 0; i < lighting_data.shadows.cascade_count; i++) {
					if (dist < lighting_data.shadows.cascade_splits[i]) {
						return i;
					}
				}
				return lighting_data.shadows.cascade_count - 1;
			}

			// PCF Shadow calculation
			float calculateShadow(vec3 world_pos, vec3 normal, vec3 light_dir) {
				int cascade_idx = getCascadeIndex(world_pos);
				if (cascade_idx < 0) return 1.0;
				
				int shadow_map_idx = lighting_data.shadows.shadow_map_indices[cascade_idx];
				if (shadow_map_idx < 0) return 1.0;
				
				float bias_val = max(0.05 * (1.0 - dot(normal, light_dir)), 0.005);
				vec3 offset_pos = world_pos + normal * bias_val;
				vec4 light_space_pos = lighting_data.shadows.light_space_matrices[cascade_idx] * vec4(offset_pos, 1.0);
				vec3 proj_coords = light_space_pos.xyz / light_space_pos.w;
				proj_coords.xy = proj_coords.xy * 0.5 + 0.5;
				
				if (proj_coords.z > 1.0 || proj_coords.z < 0.0 || proj_coords.x < 0.0 || proj_coords.x > 1.0 || proj_coords.y < 0.0 || proj_coords.y > 1.0) {
					return 1.0;
				}
				vec2 texel_size = 1.0 / textureSize(TEXTURE(shadow_map_idx), 0);
				float current_depth = proj_coords.z;
				float shadow_val = 0.0;
				for (int x = -1; x <= 1; ++x) {
					for (int y = -1; y <= 1; ++y) {
						float pcf_depth = texture(TEXTURE(shadow_map_idx), proj_coords.xy + vec2(x, y) * texel_size).r;
						shadow_val += current_depth - 0.001 > pcf_depth ? 0.0 : 1.0;
					}
				}
				return shadow_val / 9.0;
			}

			vec3 parallax_sphere(vec3 R, vec3 ray_origin, float sphere_radius) {
				float b = dot(ray_origin, R);
				float c = dot(ray_origin, ray_origin) - sphere_radius * sphere_radius;
				float discriminant = b * b - c;
				if (discriminant >= 0.0) {
					float t = -b + sqrt(discriminant);
					return normalize(ray_origin + t * R);
				}
				return R;
			}



			vec3 parallax_depth(vec3 R, vec3 ray_origin, float sphere_radius, int depth_tex, float roughness) {
				const int MAX_STEPS = 8;
				float t_min = 0.0;
				float t_max = sphere_radius * 2.0;

				// Binary search for intersection with actual geometry
				for (int i = 0; i < MAX_STEPS; i++) {
					float t_mid = (t_min + t_max) * 0.5;
					vec3 ray_pos = ray_origin + t_mid * R;
					vec3 ray_dir = normalize(ray_pos);
					float ray_dist = length(ray_pos);

					// Sample linearized depth from cubemap (distance from probe center)
					float max_mip = float(textureQueryLevels(CUBEMAP(depth_tex)) - 1);

					float stored_depth = textureLod(CUBEMAP(depth_tex), ray_dir, 0).r;

					if (ray_dist < stored_depth) {
						t_min = t_mid;  // Ray is in front of geometry, move forward
					} else {
						t_max = t_mid;  // Ray is behind geometry, move backward
					}
				}

				return normalize(ray_origin + t_max * R);
			}

			vec3 get_reflection(vec3 normal, float roughness, vec3 V, vec3 world_pos) {
				vec3 R = reflect(-V, normal);
				R = mix(R, normal, roughness * roughness);

				vec3 global_env = vec3(0.0);
				int global_tex_idx = lighting_data.env_tex;
				if (global_tex_idx != -1) {
					float max_mip = float(textureQueryLevels(CUBEMAP(global_tex_idx)) - 1);
					global_env = textureLod(CUBEMAP(global_tex_idx), R, roughness * max_mip).rgb;
				}

				// Find the best probe based on depth accuracy
				int best_probe = -1;
				float best_score = -1.0;
				float best_depth_diff = 99999.0;
				vec3 best_probe_to_point;
				float best_sphere_radius;

				vec3 probes_env = vec3(0.0);
				float total_weight = 0.0;

				for (int i = 0; i < 64; i++) {
					int color_tex = lighting_data.probe_color_textures[i];
					int depth_tex = lighting_data.probe_depth_textures[i];
					if (color_tex == -1) continue;

					vec3 probe_pos = lighting_data.probe_positions[i].xyz;
					float sphere_radius = lighting_data.probe_positions[i].w;
					vec3 probe_to_point = world_pos - probe_pos;
					float dist_to_point = length(probe_to_point);

					if (dist_to_point < sphere_radius) {
						vec3 dir_to_point = normalize(probe_to_point);

						// Check visibility and how accurately this probe sees the surface
						float stored_depth = texture(CUBEMAP(depth_tex), dir_to_point).r;
						float depth_diff = abs(stored_depth - dist_to_point);
						float bias = 0.3;

						// Surface must be visible (not behind geometry)
						if (dist_to_point > stored_depth + bias) continue;

						// Weight based on depth match quality - closer match = higher weight
						// Using exponential falloff for smoother blending
						float depth_weight = exp(-depth_diff * 0.5); // Tune the 0.5 multiplier
						
						// Also weight by distance from probe center for smooth edge falloff
						float edge_weight = smoothstep(sphere_radius, sphere_radius * 0.3, dist_to_point);
						
						float weight = depth_weight * edge_weight;

						if (weight > 0.001) {
							vec3 corrected_R = parallax_depth(R, probe_to_point, sphere_radius, depth_tex, roughness);
							float max_mip = float(textureQueryLevels(CUBEMAP(color_tex)) - 1);
							probes_env += textureLod(CUBEMAP(color_tex), corrected_R, roughness * max_mip).rgb * weight;
							total_weight += weight;
						}
					}
				}

				vec3 env = mix(global_env, probes_env / max(total_weight, 0.0001), min(total_weight, 1.0));

				//vec4 ssr = texture(TEXTURE(lighting_data.ssr_tex), in_uv);
				//env = mix(env, ssr.rgb, ssr.a);

				return env;
			}

			vec3 get_irradiance(vec3 normal, vec3 V, vec3 world_pos) {
				return get_reflection(normal, 1, V, world_pos);
			}

			float get_ambient_occlusion(vec2 uv, vec3 world_pos, vec3 N) {
				float ao_tex = get_ao();

				if (lighting_data.blue_noise_tex == -1) return ao_tex;

				vec3 p = (lighting_data.view * vec4(world_pos, 1.0)).xyz;
				vec3 V = normalize(-p);
				vec3 view_normal = normalize(mat3(lighting_data.view) * N);

				ivec2 screen_size = textureSize(TEXTURE(lighting_data.depth_tex), 0);
				ivec2 pixel = ivec2(uv * vec2(screen_size));
				ivec2 noise_size = textureSize(TEXTURE(lighting_data.blue_noise_tex), 0);
				vec2 noise = texelFetch(TEXTURE(lighting_data.blue_noise_tex), pixel % noise_size, 0).rg;
				
				float random_offset = noise.x;
				float random_rotation = noise.y * 6.28318;

				float world_radius = 2.0;
				// radius_uv = (world_radius * focal_length / -p.z) * 0.5
				float screen_radius = (world_radius * lighting_data.projection[0][0]) / (-p.z * 2.0);

				const int Nd = 4; // Slices
				const int Ns = 12; // Steps per side
				const uint Nb = 32;
				float thickness = 0.025; 
				float bias = 0.2;

				float total_ao = 0.0;
				float total_weight = 0.0;

				for (int i = 0; i < Nd; i++) {
					float angle = (float(i) / float(Nd)) * 3.14159 + random_rotation;
					vec2 dir = vec2(cos(angle), sin(angle));
					
					vec4 dir_v = lighting_data.inv_projection * vec4(dir, 0.0, 0.0);
					vec3 T_v = normalize(dir_v.xyz);
					T_v = normalize(T_v - V * dot(T_v, V));

					vec3 M = cross(V, T_v);
					vec3 n_proj = view_normal - M * dot(view_normal, M);
					float n_proj_len = length(n_proj);
					
					float weight = max(0.0, n_proj_len);
					if (weight < 0.001) continue;
					
					float theta_n = atan(dot(n_proj, T_v), dot(n_proj, V));

					uint bi = 0u;
					for (int j = 0; j < Ns; j++) {
						// Exponential stepping for better local detail
						float o = (float(j) + random_offset) / float(Ns);
						float step_dist = o * o * screen_radius;
						
						for (float side = -1.0; side <= 1.0; side += 2.0) {
							if (side == 0.0) continue;
							vec2 sample_uv = uv + dir * step_dist * side;
							
							if (sample_uv.x < 0.0 || sample_uv.x > 1.0 || sample_uv.y < 0.0 || sample_uv.y > 1.0) continue;

							float sample_depth = texture(TEXTURE(lighting_data.depth_tex), sample_uv).r;
							vec4 sample_clip_pos = vec4(sample_uv * 2.0 - 1.0, sample_depth, 1.0);
							vec4 sample_view_pos = lighting_data.inv_projection * sample_clip_pos;
							vec3 sf = sample_view_pos.xyz / sample_view_pos.w;
							
							vec3 v_f = sf - p;
							float dist2 = dot(v_f, v_f);
							
							if (dist2 > world_radius * world_radius || dist2 < 0.0001) continue;
							
							float proj_T = dot(v_f, T_v);
							float proj_V = dot(v_f, V);
							
							// Skip samples that are too close to the surface or behind it to avoid self-occlusion
							if (proj_V < bias) continue;

							float theta_f = atan(proj_T, proj_V);
							// Thickness model: assume sample has a fixed thickness along the view vector
							float theta_b = atan(proj_T, proj_V - thickness);
							
							float diff_f = theta_f - theta_n;
							if (diff_f > 3.14159) diff_f -= 6.28318;
							if (diff_f < -3.14159) diff_f += 6.28318;
							
							float diff_b = theta_b - theta_n;
							if (diff_b > 3.14159) diff_b -= 6.28318;
							if (diff_b < -3.14159) diff_b += 6.28318;

							float theta_min = clamp(min(diff_f, diff_b), -1.5708, 1.5708);
							float theta_max = clamp(max(diff_f, diff_b), -1.5708, 1.5708);
							
							uint a = uint(floor((theta_min + 1.5708) / 3.14159 * float(Nb)));
							uint b = uint(ceil((theta_max + 1.5708) / 3.14159 * float(Nb)));
							
							a = clamp(a, 0u, Nb);
							b = clamp(b, 0u, Nb);

							if (b > a) {
								uint count = b - a;
								uint mask = (count >= 32u) ? 0xFFFFFFFFu : ((1u << count) - 1u) << a;
								bi |= mask;
							}
						}
					}
					total_ao += (1.0 - float(bitCount(bi)) / float(Nb)) * weight;
					total_weight += weight;
				}

				float ao = (total_weight > 0.001) ? (total_ao / total_weight) : 1.0;
				return pow(clamp(ao, 0.0, 1.0), 1) * ao_tex;
			}

			vec3 get_sky() {
				// Skybox or background
				vec4 clip_pos = vec4(in_uv * 2.0 - 1.0, 1.0, 1.0);
				vec4 view_pos = lighting_data.inv_projection * clip_pos;
				view_pos /= view_pos.w;
				vec3 world_pos = (lighting_data.inv_view * view_pos).xyz;
				vec3 sky_dir = normalize(world_pos - lighting_data.camera_position.xyz);

				vec3 sunDir = vec3(0, 1, 0);
				if (lighting_data.light_count > 0) {
					vec3 p = lighting_data.lights[0].position.xyz;
					if (length(p) > 0.0001) {
						sunDir = normalize(-p);
					}
				}
				vec3 sky_color_output = vec3(0.0);

				]] .. require("render3d.atmosphere").GetGLSLMainCode(
					"sky_dir",
					"sunDir",
					"lighting_data.camera_position.xyz",
					"lighting_data.stars_texture_index"
				) .. [[

				return clamp(sky_color_output, vec3(0.0), vec3(65504.0));
			}

			vec3 get_light(vec3 F0, float NdotV, vec3 albedo, float r2, float metallic, vec3 world_pos, vec3 V, vec3 N)
			{
				vec3 Lo = vec3(0.0);

                for (int i = 0; i < lighting_data.light_count; i++) {
                    lights_t light = lighting_data.lights[i];
                    int type = int(light.position.w);
                    vec3 L;
                    float attenuation = 1.0;
                    if (type == 0) {
                        L = normalize(-light.position.xyz);
                    } else {
                        vec3 light_to_pos = light.position.xyz - world_pos;
                        float dist = length(light_to_pos);
                        L = normalize(light_to_pos);
                        float range = light.params.x;
                        attenuation = saturate(1.0 - dist / range);
                        attenuation *= attenuation;
                    }
                    vec3 H = normalize(V + L);
                    float NoL = saturate(dot(N, L));
                    float NoH = saturate(dot(N, H));
                    float LoH = saturate(dot(L, H));

                    float D = D_GGX(r2, NoH);
                    float V_func = V_SmithGGXCorrelated(r2, NdotV, NoL);
                    vec3 F = F_Schlick(F0, LoH);

                    vec3 Fr = (D * V_func) * F;
                    vec3 kD = vec3(1.0 - metallic);
                    vec3 Fd = kD * albedo * Fd_Lambert();

                    float shadow_factor = 1.0;
                    if (i == 0 && lighting_data.shadows.shadow_map_indices[0] >= 0) {
                        shadow_factor = calculateShadow(world_pos, N, L);
                    }
                    vec3 radiance = light.color.rgb * light.color.a * attenuation;
                    Lo += (Fd + Fr) * radiance * NoL * shadow_factor;
                }

				return Lo;				
			}

			vec3 get_world_pos(float depth) {
				// Reconstruct world position from depth
				vec4 clip_pos = vec4(in_uv * 2.0 - 1.0, depth, 1.0);
				vec4 view_pos = lighting_data.inv_projection * clip_pos;
				view_pos /= view_pos.w;
				return (lighting_data.inv_view * view_pos).xyz;
			}

			vec3 get_view_normal(vec3 world_pos) {
				return normalize(lighting_data.camera_position.xyz - world_pos);
			}

			void main() {
				float alpha = get_alpha();
				if (alpha == 0.0) discard;
				
				float depth = get_depth();

				if (depth == 1.0) {
					
					set_color(vec4(get_sky(), 1.0));
					return;
				}


				vec3 N = get_normal();
				vec3 world_pos = get_world_pos(depth);
				vec3 V = get_view_normal(world_pos);


				vec3 albedo = get_albedo();
				float metallic = get_metallic();
				float roughness = get_roughness();
				vec3 emissive = get_emissive();
				vec3 reflection = get_reflection(N, roughness, V, world_pos);
				vec3 F0 = mix(vec3(0.04), albedo, metallic);
				float NdotV = max(dot(N, V), 0.001);

                vec3 Lo = get_light(F0, NdotV, albedo, roughness, metallic, world_pos, V, N);
				float ambient_occlusion = get_ambient_occlusion(in_uv, world_pos, N);

                // Diffuse IBL: use irradiance (max-mip env sample in normal direction)
                vec3 irradiance = get_irradiance(N, V, world_pos);
                vec3 F_ambient = F_SchlickRoughness(F0, NdotV, roughness);
                vec3 kD_ambient = (1.0 - F_ambient) * (1.0 - metallic);
                vec3 ambient_diffuse = kD_ambient * irradiance * albedo * ambient_occlusion;
                
                // Specular IBL with split-sum approximation
                vec2 envBRDF = envBRDFApprox(NdotV, roughness);
                vec3 ambient_specular = reflection * (F0 * envBRDF.x + envBRDF.y) * ambient_occlusion;

                vec3 ambient = ambient_diffuse + ambient_specular;
                vec3 color = ambient + Lo + emissive;

				if (lighting_data.debug_cascade_colors != 0) {
					int cascade_idx = getCascadeIndex(world_pos);
					color = mix(color, CASCADE_COLORS[cascade_idx], 0.4);
				}

				]] .. render3d.debug_mode_glsl .. [[

				set_color(vec4(color, alpha));
			}
		]],
		},
		rasterizer = {
			cull_mode = "none",
		},
		depth_stencil = {
			depth_test = false,
			depth_write = false,
		},
	},
}
