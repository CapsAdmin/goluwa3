return {
	name = "subsurface",
	category = "Subsurface",
	params = {
		{name = "Subsurface", default = 0.0},
		{name = "SubsurfaceSkinTone", default = 0.0, requires = "Subsurface"},
		{name = "SubsurfaceRadius", default = 1.0, requires = "Subsurface"},
	},
	fields = {
		{
			name = "subsurface",
			kind = "unorm4",
			default = "0.0",
			material = "get_subsurface(get_albedo_uv(uv))",
			readers = {"lighting", "subsurface"},
		},
		{
			name = "subsurface_radius",
			kind = "unorm4",
			default = "1.0",
			encode = "clamp(log2(max(v, 0.001)) / 0.6 + 5.0, 0.0, 15.0) / 15.0",
			decode = "exp2((v * 15.0 - 5.0) * 0.6)",
			max = 64,
			material = "factor_model.SubsurfaceRadius",
			readers = {"lighting", "subsurface"},
		},
	},
	getters = [[
		float skin_likeness(vec3 albedo) {
			vec3 c = pow(max(albedo, vec3(0.0)), vec3(1.0 / 2.2));
			float high = max(c.r, max(c.g, c.b));
			float chroma = high - min(c.r, min(c.g, c.b));

			if (c.r < high || chroma < 1e-4) return 0.0;

			float hue = 60.0 * (c.g - c.b) / chroma;
			float saturation = chroma / high;
			float hue_weight = smoothstep(-25.0, -5.0, hue) * (1.0 - smoothstep(28.0, 42.0, hue));
			float saturation_weight = smoothstep(0.08, 0.22, saturation) * (1.0 - smoothstep(0.65, 0.85, saturation));
			return hue_weight * saturation_weight * smoothstep(0.5, 0.66, high);
		}

		float get_subsurface(vec3 albedo) {
			float amount = factor_model.Subsurface;

			if (amount <= 0.0) return 0.0;

			return amount * mix(1.0, skin_likeness(albedo), factor_model.SubsurfaceSkinTone);
		}

	]],
}
