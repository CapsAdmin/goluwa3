local ibl = {}

function ibl.GetBRDFGLSLCode()
	return [[
			const float BRDF_PI = 3.14159265359;

			float pow5(float x) {
				float x2 = x * x;
				return x2 * x2 * x;
			}

			float D_GGX(float roughness, float NoH) {
				float oneMinusNoHSquared = 1.0 - NoH * NoH;
				float a = NoH * roughness;
				float k = roughness / (oneMinusNoHSquared + a * a);
				return k * (k * (1.0 / BRDF_PI));
			}

			float V_SmithGGXCorrelated(float roughness, float NoV, float NoL) {
				float a2 = roughness * roughness;
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

			vec3 F_SchlickRoughness(vec3 f0, float NdotV, float roughness) {
				float f = pow5(1.0 - NdotV);
				return f0 + (max(vec3(1.0 - roughness), f0) - f0) * f;
			}

			float Fd_Lambert() {
				return 1.0 / BRDF_PI;
			}

			vec2 envBRDFApprox(float NdotV, float roughness) {
				vec4 c0 = vec4(-1.0, -0.0275, -0.572, 0.022);
				vec4 c1 = vec4(1.0, 0.0425, 1.04, -0.04);
				vec4 r = roughness * c0 + c1;
				float a004 = min(r.x * r.x, exp2(-9.28 * NdotV)) * r.x + r.y;
				return vec2(-1.04, 1.04) * a004 + r.zw;
			}
		]]
end

function ibl.GetEnvironmentGLSLCode()
	return [[
			float get_environment_max_mip(int env_tex) {
				if (env_tex == -1) return 0.0;
				return float(textureQueryLevels(CUBEMAP(env_tex)) - 1);
			}

			vec3 correct_environment_lookup_dir(vec3 dir) {
				return normalize(vec3(dir.x, dir.y, dir.z));
			}

			vec3 get_specular_dominant_direction(vec3 reflection_dir, vec3 normal, float roughness) {
				return normalize(mix(reflection_dir, normal, roughness * roughness));
			}

			vec3 sample_environment_specular(int env_tex, vec3 reflection_dir, vec3 normal, float roughness) {
				if (env_tex == -1) return vec3(0.0);
				float max_mip = get_environment_max_mip(env_tex);
				vec3 sample_dir = correct_environment_lookup_dir(get_specular_dominant_direction(reflection_dir, normal, roughness));
				return textureLod(CUBEMAP(env_tex), sample_dir, roughness * max_mip).rgb;
			}

			vec3 sample_environment_irradiance(int env_tex, vec3 normal) {
				if (env_tex == -1) return vec3(0.0);
				float max_mip = get_environment_max_mip(env_tex);
				vec3 sample_dir = correct_environment_lookup_dir(normalize(mix(vec3(0.0, 1.0, 0.0), normal, 0.35)));
				return textureLod(CUBEMAP(env_tex), sample_dir, max_mip * 0.8).rgb;
			}
		]]
end

function ibl.GetReflectionGLSLCode(uniform_name)
	uniform_name = uniform_name or "lighting_data"
	return [[
			vec3 blend_environment_sources(vec3 global_env, vec3 local_env, float local_weight) {
				return mix(global_env, local_env, clamp(local_weight, 0.0, 1.0));
			}

			float get_ssr_blend_weight(float roughness) {
				float stable_weight = 1.0 - smoothstep(0.08, 0.45, clamp(roughness, 0.0, 1.0));
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

				vec2 texel_size = 1.0 / vec2(textureSize(TEXTURE(]] .. uniform_name .. [[.ssr_tex), 0));
				vec4 center = texture(TEXTURE(]] .. uniform_name .. [[.ssr_tex), uv);

				if (center.a <= 1e-5) {
					return vec4(center.rgb, 0.0);
				}

				float center_depth = texture(TEXTURE(]] .. uniform_name .. [[.depth_tex), uv).r;
				float center_view_depth = reconstruct_ssr_view_depth(uv, center_depth);
				vec3 center_normal = texture(TEXTURE(]] .. uniform_name .. [[.normal_tex), uv).xyz;
				float center_roughness = texture(TEXTURE(]] .. uniform_name .. [[.mra_tex), uv).g;
				vec3 color_accum = center.rgb * max(center.a, 0.0) * 4.0;
				float color_weight = max(center.a, 0.0) * 4.0;
				float confidence_accum = max(center.a, 0.0) * 4.0;
				float confidence_weight = 4.0;

				for (int i = 0; i < 4; i++) {
					vec2 offset = vec2(0.0);

					if (i == 0) offset = vec2(texel_size.x, 0.0);
					else if (i == 1) offset = vec2(-texel_size.x, 0.0);
					else if (i == 2) offset = vec2(0.0, texel_size.y);
					else offset = vec2(0.0, -texel_size.y);

					vec2 tap_uv = clamp(uv + offset, vec2(0.001), vec2(0.999));
					vec4 tap = texture(TEXTURE(]] .. uniform_name .. [[.ssr_tex), tap_uv);
					float tap_depth = texture(TEXTURE(]] .. uniform_name .. [[.depth_tex), tap_uv).r;
					float tap_view_depth = reconstruct_ssr_view_depth(tap_uv, tap_depth);
					vec3 tap_normal = texture(TEXTURE(]] .. uniform_name .. [[.normal_tex), tap_uv).xyz;
					float tap_roughness = texture(TEXTURE(]] .. uniform_name .. [[.mra_tex), tap_uv).g;
					float depth_scale = max(abs(center_view_depth) * 0.02, 0.05);
					float depth_weight = exp(-abs(tap_view_depth - center_view_depth) / depth_scale);
					float normal_weight = pow(max(dot(center_normal, tap_normal), 0.0), 32.0);
					float roughness_weight = 1.0 - clamp(abs(tap_roughness - center_roughness) * 8.0, 0.0, 1.0);
					float geometry_weight = depth_weight * normal_weight * roughness_weight;
					float tap_weight = geometry_weight * max(tap.a, 0.0);
					color_accum += tap.rgb * tap_weight;
					color_weight += tap_weight;
					confidence_accum += max(tap.a, 0.0) * geometry_weight;
					confidence_weight += geometry_weight;
				}

				if (color_weight <= 1e-5 || confidence_weight <= 1e-5) return vec4(center.rgb, 0.0);

				vec3 filtered_rgb = color_accum / color_weight;
				float filtered_confidence = clamp(confidence_accum / confidence_weight, 0.0, 1.0);
				filtered_confidence = smoothstep(0.35, 0.9, filtered_confidence);
				return vec4(filtered_rgb, filtered_confidence);
			}

			vec3 combine_reflections(vec3 env_reflection, vec4 ssr_reflection, float ssr_weight) {
				return mix(env_reflection, ssr_reflection.rgb, clamp(ssr_reflection.a * ssr_weight, 0.0, 1.0));
			}
		]]
end

return ibl
