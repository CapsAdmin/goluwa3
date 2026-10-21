return {
	name = "core",
	fields = {
		{name = "normal", kind = "octa", member = false},
		{
			name = "metallic",
			kind = "unorm8",
			default = "0.0",
			material = "get_metallic(uv)",
		},
		{
			name = "roughness",
			member = "roughness_alpha",
			kind = "unorm8",
			default = "1.0",
			encode = "sqrt(v)",
			decode = "v * v",
			material = "get_roughness(uv)",
		},
		{name = "ao", kind = "unorm8", default = "1.0", material = "get_ao(uv)"},
	},
	surface_members = [[
		vec3 albedo;
		vec3 emissive;
		float alpha;
	]],
	surface_default = [[
		s.albedo = vec3(1.0);
		s.emissive = vec3(0.0);
		s.alpha = 1.0;
	]],
	material_init = [[
		s.emissive = get_emissive(uv);
	]],
	weather_input = [[

		w.porosity = clamp((sqrt(s.roughness_alpha) - 0.5) / 0.4, 0.0, 1.0) * (1.0 - s.metallic);
		w.wet_scale = 1.0;
		w.snow_scale = 1.0;
		w.snow = 0.0;
		w.film = 0.0;
		w.film_alpha = 1.0;
		w.rain = 0.0;
	]],
	weather = [[
		s.ao = mix(s.ao, 1.0, w.snow);
		s.emissive *= 1.0 - w.snow;
	]],
	gbuffer_write = [[
		set_alpha(s.alpha);
		set_albedo(s.albedo);
		set_normal(gbuffer_encode_normal(s.N));
		set_emissive(gbuffer_encode_emissive(s.emissive));
	]],
	surface_decode = [[
		s.albedo = gbuffer_albedo(uv);
		s.alpha = gbuffer_alpha(uv);
		s.emissive = gbuffer_emissive(uv);
		s.perceptual_roughness = sqrt(clamp(s.roughness_alpha, 0.0, 1.0));
		s.F0 = mix(vec3(0.04), s.albedo, s.metallic);
	]],
}
