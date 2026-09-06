local ibl = {}

function ibl.GetBRDFGLSLCode()
	return [[
			const float BRDF_PI = 3.14159265359;
			#ifndef saturate
			#define saturate(x) clamp(x, 0.0, 1.0)
			#endif

			float pow5(float x) {
				float x2 = x * x;
				return x2 * x2 * x;
			}

			float D_GGXAlpha(float alpha, float NoH) {
				alpha = max(alpha, 0.0001);
				float alpha2 = alpha * alpha;
				float NoH2 = NoH * NoH;
				float denom = max(NoH2 * (alpha2 - 1.0) + 1.0, 1e-6);
				return alpha2 / (BRDF_PI * denom * denom);
			}

			float D_GGXPerceptual(float perceptual_roughness, float NoH) {
				return D_GGXAlpha(perceptual_roughness * perceptual_roughness, NoH);
			}

			float V_SmithGGXCorrelated(float alpha, float NoV, float NoL) {
				float a2 = alpha * alpha;
				float lambdaV = NoL * sqrt((NoV - a2 * NoV) * NoV + a2);
				float lambdaL = NoV * sqrt((NoL - a2 * NoL) * NoL + a2);
				return 0.5 / (lambdaV + lambdaL);
			}

			float F_SchlickScalar(float f0, float VoH) {
				float f = pow5(1.0 - VoH);
				return f0 + (1.0 - f0) * f;
			}

			vec3 F_Schlick(const vec3 f0, float VoH) {
				float f = pow5(1.0 - VoH);
				return f + f0 * (1.0 - f);
			}

			vec3 F_SchlickRoughness(vec3 f0, float NdotV, float perceptual_roughness) {
				float f = pow5(1.0 - NdotV);
				return f0 + (max(vec3(1.0 - perceptual_roughness), f0) - f0) * f;
			}

			float Fd_Lambert() {
				return 1.0 / BRDF_PI;
			}

			float Fd_Burley(float NoL, float NoV, float LoH, float perceptual_roughness) {
				float F90 = 0.5 + 2.0 * perceptual_roughness * LoH * LoH;
				float light_scatter = 1.0 + (F90 - 1.0) * pow5(1.0 - NoL);
				float view_scatter = 1.0 + (F90 - 1.0) * pow5(1.0 - NoV);
				return light_scatter * view_scatter * (1.0 / BRDF_PI);
			}

			float SpecularOcclusion(float NoV, float ambient_occlusion, float perceptual_roughness) {
				float exponent = exp2(-16.0 * perceptual_roughness - 1.0);
				return saturate(pow(NoV + ambient_occlusion, exponent) - 1.0 + ambient_occlusion);
			}

			vec3 GGXEnergyCompensation(vec3 f0, vec2 env_brdf) {
				return 1.0 + f0 * (1.0 / max(env_brdf.x + env_brdf.y, 0.001) - 1.0);
			}

			float RadicalInverse_Vdc(uint bits) {
				bits = (bits << 16u) | (bits >> 16u);
				bits = ((bits & 0x55555555u) << 1u) | ((bits & 0xAAAAAAAAu) >> 1u);
				bits = ((bits & 0x33333333u) << 2u) | ((bits & 0xCCCCCCCCu) >> 2u);
				bits = ((bits & 0x0F0F0F0Fu) << 4u) | ((bits & 0xF0F0F0F0u) >> 4u);
				bits = ((bits & 0x00FF00FFu) << 8u) | ((bits & 0xFF00FF00u) >> 8u);
				return float(bits) * 2.3283064365386963e-10;
			}

			vec2 Hammersley(uint i, uint N) {
				return vec2(float(i) / float(N), RadicalInverse_Vdc(i));
			}

			vec3 ImportanceSampleGGX(vec2 Xi, vec3 N, float perceptual_roughness) {
				float a = perceptual_roughness * perceptual_roughness;
				float phi = 2.0 * BRDF_PI * Xi.x;
				float cosTheta = sqrt((1.0 - Xi.y) / (1.0 + (a * a - 1.0) * Xi.y));
				float sinTheta = sqrt(1.0 - cosTheta * cosTheta);

				vec3 H;
				H.x = cos(phi) * sinTheta;
				H.y = sin(phi) * sinTheta;
				H.z = cosTheta;

				vec3 up = abs(N.z) < 0.999 ? vec3(0.0, 0.0, 1.0) : vec3(1.0, 0.0, 0.0);
				vec3 tangent = normalize(cross(up, N));
				vec3 bitangent = cross(N, tangent);

				vec3 sampleVec = tangent * H.x + bitangent * H.y + N * H.z;
				return normalize(sampleVec);
			}

			vec3 ImportanceSampleGGXVNDF(vec3 Ve, float alpha, vec2 xi) {
				vec3 Vh = normalize(vec3(alpha * Ve.x, alpha * Ve.y, Ve.z));
				float lensq = Vh.x * Vh.x + Vh.y * Vh.y;
				vec3 T1 = lensq > 0.0 ? vec3(-Vh.y, Vh.x, 0.0) / sqrt(lensq) : vec3(1.0, 0.0, 0.0);
				vec3 T2 = cross(Vh, T1);
				float r = sqrt(xi.x);
				float phi = 2.0 * BRDF_PI * xi.y;
				float t1 = r * cos(phi);
				float t2 = r * sin(phi);
				float s = 0.5 * (1.0 + Vh.z);
				t2 = (1.0 - s) * sqrt(1.0 - t1 * t1) + s * t2;
				vec3 Nh = t1 * T1 + t2 * T2 + sqrt(max(0.0, 1.0 - t1 * t1 - t2 * t2)) * Vh;
				return normalize(vec3(alpha * Nh.x, alpha * Nh.y, max(0.0, Nh.z)));
			}
		]]
end

-- prefiltered cubemap mips with faces smaller than this are not used for roughness lookups
ibl.ENVIRONMENT_ROUGHEST_MIP_FACE_SIZE = 16

function ibl.GetPrefilterMipCount(size)
	return math.max(
			math.floor(math.log(size / ibl.ENVIRONMENT_ROUGHEST_MIP_FACE_SIZE) / math.log(2) + 0.5),
			0
		) + 1
end

function ibl.GetEnvironmentGLSLCode()
	return [[
			const int ENVIRONMENT_ROUGHEST_MIP_SKIP = ]] .. (
			math.floor(math.log(ibl.ENVIRONMENT_ROUGHEST_MIP_FACE_SIZE) / math.log(2) + 0.5)
		) .. [[;

			// Mip that holds perceptual roughness 1. The chain stops at faces of
			// ENVIRONMENT_ROUGHEST_MIP_FACE_SIZE texels because coarser levels
			// cannot represent the wide GGX lobe without visible face seams.
			float get_environment_max_mip(int env_tex) {
				if (env_tex == -1) return 0.0;
				return max(float(textureQueryLevels(CUBEMAP(env_tex)) - 1 - ENVIRONMENT_ROUGHEST_MIP_SKIP), 0.0);
			}

			vec3 correct_environment_lookup_dir(vec3 dir) {
				return normalize(vec3(-dir.x, dir.y, dir.z));
			}

			// Frostbite's fit of the direction the GGX lobe is centered on:
			// rough surfaces reflect closer to the normal than the mirror direction.
			vec3 get_specular_dominant_direction(vec3 reflection_dir, vec3 normal, float perceptual_roughness) {
				float alpha = perceptual_roughness * perceptual_roughness;
				float lerp_factor = (1.0 - alpha) * (sqrt(1.0 - alpha) + alpha);
				return normalize(mix(normal, reflection_dir, lerp_factor));
			}

			vec3 sample_environment_specular(int env_tex, vec3 reflection_dir, vec3 normal, float perceptual_roughness) {
				if (env_tex == -1) return vec3(0.0);
				float max_mip = get_environment_max_mip(env_tex);
				vec3 sample_dir = correct_environment_lookup_dir(get_specular_dominant_direction(reflection_dir, normal, perceptual_roughness));
				float horizon = saturate(1.0 + dot(reflection_dir, normal));
				return textureLod(CUBEMAP(env_tex), sample_dir, perceptual_roughness * max_mip).rgb * horizon * horizon;
			}

			// irradiance_tex is a cosine convolved cubemap already divided by
			// pi, so the result times albedo is the diffuse outgoing radiance.
			vec3 sample_environment_irradiance(int irradiance_tex, vec3 normal) {
				if (irradiance_tex == -1) return vec3(0.0);
				return texture(CUBEMAP(irradiance_tex), correct_environment_lookup_dir(normal)).rgb;
			}
		]]
end

function ibl.GetReflectionGLSLCode(uniform_name)
	uniform_name = uniform_name or "lighting_data"
	return [[
			vec3 blend_environment_sources(vec3 global_env, vec3 local_env, float local_weight) {
				return mix(global_env, local_env, clamp(local_weight, 0.0, 1.0));
			}

			float get_ssr_blend_weight(float perceptual_roughness) {
				float stable_weight = 1.0 - smoothstep(0.08, 0.45, clamp(perceptual_roughness, 0.0, 1.0));
				return stable_weight * stable_weight;
			}

			float reconstruct_ssr_view_depth(vec2 uv, float depth) {
				vec4 clip = vec4(uv * 2.0 - 1.0, depth, 1.0);
				vec4 view_pos = ]] .. uniform_name .. [[.inv_projection * clip;
				view_pos /= max(abs(view_pos.w), 1e-5);
				return view_pos.z;
			}

			vec4 get_filtered_ssr_reflection(vec2 uv) {
				if (]] .. uniform_name .. [[.ssr_tex == -1) return vec4(0.0);
				if (uv.x <= 0.0 || uv.x >= 1.0 || uv.y <= 0.0 || uv.y >= 1.0) return vec4(0.0);

				ivec2 ssr_size = textureSize(TEXTURE(]] .. uniform_name .. [[.ssr_tex), 0);
				ivec2 gbuffer_size = textureSize(TEXTURE(]] .. uniform_name .. [[.depth_tex), 0);
				vec2 ratio = vec2(gbuffer_size) / vec2(ssr_size);
				ivec2 pixel = clamp(ivec2(uv * vec2(gbuffer_size)), ivec2(0), gbuffer_size - 1);
				float center_depth = texelFetch(TEXTURE(]] .. uniform_name .. [[.depth_tex), pixel, 0).r;

				if (center_depth >= 1.0) return vec4(0.0);

				float center_view_depth = reconstruct_ssr_view_depth(uv, center_depth);
				vec3 center_normal = texelFetch(TEXTURE(]] .. uniform_name .. [[.normal_tex), pixel, 0).xyz;
				float center_roughness = texelFetch(TEXTURE(]] .. uniform_name .. [[.mra_tex), pixel, 0).g;
				vec2 ssr_coord = uv * vec2(ssr_size) - 0.5;
				ivec2 ssr_base = ivec2(floor(ssr_coord));
				vec2 ssr_frac = ssr_coord - vec2(ssr_base);
				vec4 accum = vec4(0.0);
				float total_weight = 0.0;

				for (int i = 0; i < 4; i++) {
					ivec2 offset = ivec2(i & 1, i >> 1);
					ivec2 ssr_pos = clamp(ssr_base + offset, ivec2(0), ssr_size - 1);
					ivec2 tap_pixel = min(ivec2((vec2(ssr_pos) + 0.5) * ratio), gbuffer_size - 1);
					float tap_depth = texelFetch(TEXTURE(]] .. uniform_name .. [[.depth_tex), tap_pixel, 0).r;

					if (tap_depth >= 1.0) continue;

					vec2 tap_uv = (vec2(tap_pixel) + 0.5) / vec2(gbuffer_size);
					float tap_view_depth = reconstruct_ssr_view_depth(tap_uv, tap_depth);
					vec3 tap_normal = texelFetch(TEXTURE(]] .. uniform_name .. [[.normal_tex), tap_pixel, 0).xyz;
					float tap_roughness = texelFetch(TEXTURE(]] .. uniform_name .. [[.mra_tex), tap_pixel, 0).g;
					float bilinear_weight = (offset.x == 0 ? 1.0 - ssr_frac.x : ssr_frac.x) * (offset.y == 0 ? 1.0 - ssr_frac.y : ssr_frac.y);
					float depth_weight = exp(-abs(tap_view_depth - center_view_depth) / max(abs(center_view_depth) * 0.03, 0.05));
					float normal_weight = pow(max(dot(center_normal, tap_normal), 0.0), 16.0);
					float roughness_weight = 1.0 - clamp(abs(tap_roughness - center_roughness) * 8.0, 0.0, 1.0);
					float weight = bilinear_weight * (depth_weight * normal_weight * roughness_weight + 1e-4);
					accum += texelFetch(TEXTURE(]] .. uniform_name .. [[.ssr_tex), ssr_pos, 0) * weight;
					total_weight += weight;
				}

				if (total_weight <= 1e-6) return texture(TEXTURE(]] .. uniform_name .. [[.ssr_tex), uv);

				vec4 filtered = accum / total_weight;
				return vec4(filtered.rgb, clamp(filtered.a, 0.0, 1.0));
			}

			vec3 combine_reflections(vec3 env_reflection, vec4 ssr_reflection, float ssr_weight) {
				return mix(env_reflection, ssr_reflection.rgb, clamp(ssr_reflection.a * ssr_weight, 0.0, 1.0));
			}
		]]
end

-- Samples reflection probes uploaded to uniform_name.probe_color_textures /
-- probe_depth_textures / probe_positions (see envprobe.GetProbeBlockLayout
-- / WriteProbeBlock) and blends them over global_env. Shared by ssr.lua
-- (as its screen-space-miss fallback) and lighting.lua (so probes still
-- contribute when the SSR pass itself is disabled).
function ibl.GetProbeReflectionGLSLCode(uniform_name)
	uniform_name = uniform_name or "lighting_data"
	return [[
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

			// Blends global_env (sky/GI/whatever the caller already resolved
			// for a total miss) with any reflection probes near world_pos,
			// weighted by depth-based coverage confidence.
			vec3 blend_probe_reflections(vec3 global_env, vec3 R, float roughness, vec3 world_pos) {
				vec3 probes_env = vec3(0.0);
				float total_weight = 0.0;
				float normalized_weight_sum = 0.0;
				float max_weight = 0.0;

				for (int i = 0; i < 64; i++) {
					int color_tex = ]] .. uniform_name .. [[.probe_color_textures[i];
					int depth_tex = ]] .. uniform_name .. [[.probe_depth_textures[i];
					if (color_tex == -1) continue;

					vec3 probe_pos = ]] .. uniform_name .. [[.probe_positions[i].xyz;
					float sphere_radius = ]] .. uniform_name .. [[.probe_positions[i].w;
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
							float probe_max_mip = get_environment_max_mip(color_tex);
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
		]]
end

return ibl
