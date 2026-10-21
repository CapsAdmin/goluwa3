return {
	name = "sheen",
	category = "Sheen",
	params = {
		{name = "Sheen", default = 0.0, getter = "get_sheen"},
		{
			name = "SheenRoughness",
			default = 0.5,
			requires = "Sheen",
			getter = "get_sheen_roughness",
			getter_expression = "clamp(v, 0.07, 1.0)",
		},
	},
	fields = {
		{
			name = "sheen",
			kind = "unorm4",
			default = "0.0",
			material = "get_sheen()",
			readers = {"lighting"},
		},
		{
			name = "sheen_roughness",
			sheet = "sheen",
			kind = "unorm4",
			default = "1.0",
			material = "get_sheen_roughness()",
			readers = {"lighting"},
		},
	},
	common = [[
		float D_Charlie(float roughness, float NoH) {
			float inverse_alpha = 1.0 / max(roughness * roughness, 1e-3);
			float sin2 = max(1.0 - NoH * NoH, 0.0078125);
			return (2.0 + inverse_alpha) * pow(sin2, inverse_alpha * 0.5) / (2.0 * PI);
		}

		float V_Neubelt(float NoV, float NoL) {
			return 1.0 / (4.0 * (NoL + NoV - NoL * NoV));
		}

		const float SHEEN_ALBEDO_TABLE[64] = float[64](
			1.0000, 0.3156, 0.0135, 0.0002, 0.0000, 0.0000, 0.0000, 0.0000,
			1.0000, 0.6897, 0.2771, 0.1029, 0.0324, 0.0076, 0.0010, 0.0000,
			1.0000, 0.6426, 0.3748, 0.2155, 0.1165, 0.0560, 0.0212, 0.0036,
			0.8740, 0.5801, 0.3942, 0.2689, 0.1781, 0.1107, 0.0606, 0.0241,
			0.7475, 0.5332, 0.3930, 0.2932, 0.2156, 0.1527, 0.1005, 0.0567,
			0.6711, 0.5002, 0.3871, 0.3047, 0.2385, 0.1825, 0.1336, 0.0899,
			0.6218, 0.4768, 0.3810, 0.3106, 0.2532, 0.2037, 0.1594, 0.1185,
			0.5882, 0.4599, 0.3757, 0.3138, 0.2631, 0.2190, 0.1790, 0.1418
		);

		float get_sheen_albedo(float NoV, float roughness) {
			vec2 grid = vec2(saturate(NoV), saturate((roughness - 0.07) / 0.93)) * 7.0;
			ivec2 cell = min(ivec2(grid), ivec2(6));
			vec2 weight = grid - vec2(cell);
			int index = cell.y * 8 + cell.x;
			float low = mix(SHEEN_ALBEDO_TABLE[index], SHEEN_ALBEDO_TABLE[index + 1], weight.x);
			float high = mix(SHEEN_ALBEDO_TABLE[index + 8], SHEEN_ALBEDO_TABLE[index + 9], weight.x);
			return mix(low, high, weight.y);
		}
	]],
	direct_layer = [[
		if (s.sheen > 0.0) {
			float sheen_NoL = saturate(dot(s.N, L));
			vec3 sheen_color = s.sheen * s.albedo / max(max(s.albedo.r, max(s.albedo.g, s.albedo.b)), 0.001);
			specular += D_Charlie(s.sheen_roughness, saturate(dot(s.N, H))) * V_Neubelt(s.NdotV, sheen_NoL) * sheen_color * radiance * sheen_NoL;
			float sheen_scaling = min(1.0 - s.sheen * get_sheen_albedo(s.NdotV, s.sheen_roughness), 1.0 - s.sheen * get_sheen_albedo(sheen_NoL, s.sheen_roughness));
			radiance *= max(sheen_scaling, 0.0);
		}
	]],
	indirect_layer = [[
		if (s.sheen > 0.0) {
			float lobe_albedo = get_sheen_albedo(s.NdotV, s.sheen_roughness);
			float sheen_albedo = s.sheen * lobe_albedo;
			vec3 sheen_color = s.sheen * s.albedo / max(max(s.albedo.r, max(s.albedo.g, s.albedo.b)), 0.001);
			ambient_diffuse *= 1.0 - sheen_albedo;
			ambient_specular = ambient_specular * (1.0 - sheen_albedo) + sheen_color * lobe_albedo * irradiance * ambient_occlusion;
		}
	]],
}
