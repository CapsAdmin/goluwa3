return {
	name = "derived_roughness",
	category = "Derived Roughness",
	params = {
		{
			name = "DerivedRoughnessAlbedo",
			default = 0.0,
			getter = "get_derived_roughness_albedo",
		},
		{
			name = "DerivedRoughnessAlbedoMean",
			default = 0.5,
			requires = "DerivedRoughnessAlbedo",
			getter = "get_derived_roughness_albedo_mean",
		},
		{
			name = "DerivedRoughnessNormal",
			default = 0.0,
			getter = "get_derived_roughness_normal",
		},
		{
			name = "DerivedRoughnessMetal",
			default = 0.0,
			getter = "get_derived_roughness_metal",
		},
		{
			name = "DerivedSpecularCavity",
			default = 0.0,
			getter = "get_derived_specular_cavity",
		},
		{
			name = "DerivedMetalAlbedo",
			default = 0.0,
			getter = "get_derived_metal_albedo",
		},
		{
			name = "DerivedSpecularRoughness",
			default = 0.0,
			getter = "get_derived_specular_roughness",
		},
	},
	material_init = [[
		if (get_derived_metal_albedo() > 0.0 && s.metallic > 0.0 && model.AlbedoTexture != -1) {
			vec3 texel = texture(TEXTURE(model.AlbedoTexture), base_uv(uv), 2.0).rgb;
			float high = max(texel.r, max(texel.g, texel.b));
			float saturation = high > 0.0 ? (high - min(texel.r, min(texel.g, texel.b))) / high : 0.0;
			float gate = (1.0 - smoothstep(0.25, 0.55, saturation)) * smoothstep(0.02, 0.08, luminance(texel));
			float perceptual = sqrt(s.roughness_alpha);
			perceptual = mix(perceptual, max(perceptual, 0.8), (1.0 - gate) * get_derived_metal_albedo());
			s.roughness_alpha = perceptual * perceptual;
			s.metallic *= mix(1.0, gate, get_derived_metal_albedo());
		}

		if ((get_derived_roughness_albedo() > 0.0 || get_derived_roughness_normal() > 0.0 || get_derived_specular_cavity() > 0.0) && get_roughness_texel(uv) < 0.0) {
			float derived = sqrt(s.roughness_alpha);
			float cavity = 0.0;
			float contrast = 1.0 + get_derived_roughness_metal() * s.metallic;

			if (model.AlbedoTexture != -1) {
				float darker = get_derived_roughness_albedo_mean() - sqrt(luminance(get_albedo_uv(uv)));
				derived += get_derived_roughness_albedo() * contrast * darker;
				cavity = clamp(darker / max(get_derived_roughness_albedo_mean(), 0.05), 0.0, 1.0);
			}

			if (model.NormalTexture != -1) {
				float lean = 1.0 - clamp(get_normal_map(uv).z, 0.0, 1.0);
				derived += get_derived_roughness_normal() * contrast * lean;
				cavity = max(cavity, clamp(lean * 4.0, 0.0, 1.0));
			}

			s.roughness_alpha = clamp(derived * derived, 0.002, 1.0);
			s.specular *= 1.0 - get_derived_specular_cavity() * cavity;
		}
	
		if (get_derived_specular_roughness() > 0.0) {
			s.specular *= 1.0 - get_derived_specular_roughness() * smoothstep(0.4, 1.0, sqrt(s.roughness_alpha)) * (1.0 - s.metallic);
		}
	]],
}
