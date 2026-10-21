return {
	name = "secondary_specular",
	category = "Secondary Specular",
	params = {
		{name = "SecondarySpecular", default = 0.0, getter = "get_secondary_specular"},
		{
			name = "SecondarySpecularRoughness",
			default = 0.3,
			requires = "SecondarySpecular",
			getter = "get_secondary_specular_roughness",
			getter_expression = "v * v",
		},
	},
	fields = {
		{
			name = "secondary_specular",
			sheet = "specular",
			kind = "unorm4",
			default = "0.0",
			material = "get_secondary_specular()",
			readers = {"lighting"},
		},
		{
			name = "secondary_specular_roughness",
			sheet = "specular",
			member = "secondary_specular_alpha",
			material = "get_secondary_specular_roughness()",
			kind = "unorm8",
			default = "1.0",
			encode = "sqrt(v)",
			decode = "v * v",
			readers = {"lighting"},
		},
	},
	reflection = [[

		if (gbuffer_secondary_specular(gbuffer_pos) > 0.5) {
			roughness = min(roughness, sqrt(gbuffer_secondary_specular_roughness(gbuffer_pos)));
		}
	]],
	direct_peak = [[
		if (s.secondary_specular > 0.0) lobe_alpha_min = min(lobe_alpha_min, s.secondary_specular_alpha);
	]],
	direct = [[
		if (s.secondary_specular > 0.0) {
			float lobe2_alpha = s.secondary_specular_alpha;
			float lobe2_energy = 1.0;

			if (type == 0) {
				lobe2_alpha = saturate(s.secondary_specular_alpha + SUN_ANGULAR_RADIUS * 0.5);
				lobe2_energy = s.secondary_specular_alpha / lobe2_alpha;
				lobe2_energy *= lobe2_energy;
			} else if (glow_widening > 0.0) {
				lobe2_alpha = saturate(s.secondary_specular_alpha + glow_widening);
				lobe2_energy = s.secondary_specular_alpha / lobe2_alpha;
				lobe2_energy *= lobe2_energy;
			}

			float lobe2_NoL = saturate(dot(s.N, L));
			float lobe2_NoH = saturate(dot(s.N, H));
			specular += D_GGXAlpha(lobe2_alpha, lobe2_NoH) * lobe2_energy * V_SmithGGXCorrelated(s.secondary_specular_alpha, s.NdotV, lobe2_NoL) * F_SchlickScalar(0.04, LoH) * s.secondary_specular * radiance * lobe2_NoL;
		}
	]],
	indirect = [[
		if (s.secondary_specular > 0.0) {
			float lobe2_roughness = sqrt(clamp(s.secondary_specular_alpha, 0.0, 1.0));
			vec3 lobe2_reflection = get_reflection(s.N, lobe2_roughness, s.V, s.world_pos, sky_visibility, irradiance, in_uv);
			ambient_specular += lobe2_reflection * F_SchlickScalar(0.04, s.NdotV) * s.secondary_specular * SpecularOcclusion(s.NdotV, ambient_occlusion, lobe2_roughness);
		}
	]],
}
