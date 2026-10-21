return {
	name = "specular_tint",
	category = "Specular Tint",
	params = {
		{name = "SpecularTint", default = 0.0, getter = "get_specular_tint"},
	},
	fields = {
		{name = "specular_tint", sheet = "specular", kind = "unorm4", default = "0.0", material = "get_specular_tint()", readers = {"lighting"}},
	},
	surface_finish = [[
		if (s.specular_tint > 0.0) {
			vec3 chroma = s.albedo / max(max(s.albedo.r, max(s.albedo.g, s.albedo.b)), 0.001);
			s.F0 *= mix(vec3(1.0), chroma, s.specular_tint * (1.0 - s.metallic));
		}
	]],
}
