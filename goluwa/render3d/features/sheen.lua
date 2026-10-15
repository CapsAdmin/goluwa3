-- the soft rim of cloth, light scattered by fibres standing up from the surface. a charlie lobe
-- (Estevez and Kulla 2017) with the neubelt visibility. the color is white, which makes the
-- energy it takes from the base lobe an approximation we leave out
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
		{name = "sheen", kind = "unorm4", default = "0.0", material = "get_sheen()", readers = {"lighting"}},
		{
			name = "sheen_roughness",
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
	]],
	direct = [[
		if (s.sheen > 0.0) {
			float sheen_NoL = saturate(dot(s.N, L));
			specular += D_Charlie(s.sheen_roughness, saturate(dot(s.N, H))) * V_Neubelt(s.NdotV, sheen_NoL) * s.sheen * radiance * sheen_NoL;
		}
	]],
	indirect = [[
		if (s.sheen > 0.0) {
			// the lobe is broad, the irradiance stands in for what it gathers of the environment
			float sheen_rim = 1.0 - s.NdotV;
			ambient_specular += s.sheen * irradiance * ambient_occlusion * (0.02 + 0.4 * sheen_rim * sheen_rim);
		}
	]],
}
