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

			vec3 get_specular_dominant_direction(vec3 reflection_dir, vec3 normal, float roughness) {
				return normalize(mix(reflection_dir, normal, roughness * roughness));
			}

			vec3 sample_environment_specular(int env_tex, vec3 reflection_dir, vec3 normal, float roughness) {
				if (env_tex == -1) return vec3(0.0);
				float max_mip = get_environment_max_mip(env_tex);
				vec3 sample_dir = get_specular_dominant_direction(reflection_dir, normal, roughness);
				return textureLod(CUBEMAP(env_tex), sample_dir, roughness * max_mip).rgb;
			}

			vec3 sample_environment_irradiance(int env_tex, vec3 normal) {
				if (env_tex == -1) return vec3(0.0);
				float max_mip = get_environment_max_mip(env_tex);
				vec3 sample_dir = normalize(mix(vec3(0.0, 1.0, 0.0), normal, 0.35));
				return textureLod(CUBEMAP(env_tex), sample_dir, max_mip * 0.8).rgb;
			}
		]]
end

function ibl.GetReflectionGLSLCode(ssr_uniform_name)
	ssr_uniform_name = ssr_uniform_name or "ssr_tex"
	return [[
			vec3 blend_environment_sources(vec3 global_env, vec3 local_env, float local_weight) {
				return mix(global_env, local_env, clamp(local_weight, 0.0, 1.0));
			}

			vec4 get_filtered_ssr_reflection(int ssr_tex, vec2 uv) {
				if (ssr_tex == -1) return vec4(0.0);
				if (uv.x <= 0.0 || uv.x >= 1.0 || uv.y <= 0.0 || uv.y >= 1.0) return vec4(0.0);

				vec2 texel_size = 1.0 / vec2(textureSize(TEXTURE(ssr_tex), 0));
				vec4 center = texture(TEXTURE(ssr_tex), uv);
				vec4 accum = vec4(center.rgb * center.a, center.a) * 4.0;
				float total_weight = max(center.a, 0.0) * 4.0;

				for (int i = 0; i < 4; i++) {
					vec2 offset = vec2(0.0);

					if (i == 0) offset = vec2(texel_size.x, 0.0);
					else if (i == 1) offset = vec2(-texel_size.x, 0.0);
					else if (i == 2) offset = vec2(0.0, texel_size.y);
					else offset = vec2(0.0, -texel_size.y);

					vec2 tap_uv = clamp(uv + offset, vec2(0.001), vec2(0.999));
					vec4 tap = texture(TEXTURE(ssr_tex), tap_uv);
					float tap_weight = max(tap.a, 0.0);
					accum += vec4(tap.rgb * tap_weight, tap.a);
					total_weight += tap_weight;
				}

				if (total_weight <= 1e-5) return vec4(0.0);

				vec3 filtered_rgb = accum.rgb / total_weight;
				float filtered_confidence = clamp(accum.a / 8.0, 0.0, 1.0);
				filtered_confidence = smoothstep(0.35, 0.9, filtered_confidence);
				return vec4(filtered_rgb, filtered_confidence);
			}

			vec3 combine_reflections(vec3 env_reflection, vec4 ssr_reflection, float ssr_weight) {
				return mix(env_reflection, ssr_reflection.rgb, clamp(ssr_reflection.a * ssr_weight, 0.0, 1.0));
			}
		]]
end

return ibl
