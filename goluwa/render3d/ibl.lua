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

function ibl.GetEnvironmentGLSLCode()
	return [[
			float get_environment_max_mip(int env_tex) {
				if (env_tex == -1) return 0.0;
				return float(textureQueryLevels(CUBEMAP(env_tex)) - 1);
			}

			vec3 correct_environment_lookup_dir(vec3 dir) {
				return normalize(vec3(-dir.x, dir.y, dir.z));
			}

			vec3 get_specular_dominant_direction(vec3 reflection_dir, vec3 normal, float perceptual_roughness) {
				return normalize(mix(reflection_dir, normal, perceptual_roughness * perceptual_roughness));
			}

			vec3 sample_environment_specular(int env_tex, vec3 reflection_dir, vec3 normal, float perceptual_roughness) {
				if (env_tex == -1) return vec3(0.0);
				float max_mip = get_environment_max_mip(env_tex);
				vec3 sample_dir = correct_environment_lookup_dir(get_specular_dominant_direction(reflection_dir, normal, perceptual_roughness));
				float horizon = saturate(1.0 + dot(reflection_dir, normal));
				return textureLod(CUBEMAP(env_tex), sample_dir, perceptual_roughness * max_mip).rgb * horizon * horizon;
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

return ibl
