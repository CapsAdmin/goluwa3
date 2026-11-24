return {
	name = "sky_window",
	category = "Emission",
	params = {
		{name = "SkyWindow", default = 0.0, getter = "get_sky_window"},
	},
	fields = {
		{
			name = "sky_window",
			kind = "unorm4",
			default = "0.0",
			material = "get_sky_window()",
			readers = {"lighting"},
		},
	},
	surface_finish = [[
		if (s.sky_window > 0.0) {
			vec3 sky = sample_environment_specular(lighting_data.env_tex, -s.V, -s.V, s.perceptual_roughness);
			s.emissive = mix(s.emissive, s.emissive / EMISSIVE_REFERENCE_LUMINANCE * sky, s.sky_window);
		}
	]],
}
