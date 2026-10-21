return {
	name = "specular",
	fields = {
		{
			name = "specular",
			kind = "unorm8",
			default = "1.0",
			encode = "clamp(v * 0.5, 0.0, 1.0)",
			decode = "v * 2.0",
			max = 2,
			material = "get_specular(uv)",
			readers = {"lighting"},
		},
	},
	weather = [[

		s.specular = mix(s.specular, 0.45, w.snow);
	]],
	surface_decode = [[
		s.F0 = mix(vec3(0.04 * s.specular), s.albedo, s.metallic);
	]],
}
