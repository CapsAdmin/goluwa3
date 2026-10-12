-- the reflectance of a dielectric head on, F0 = 0.04 * specular. a metal's comes from its albedo.
-- the material params (SpecularMultiplier and its texture, with the gloss and the metallic
-- conversion) stay in material.lua and model_pipeline.lua, they are tangled up with the channel
-- packing flags
return {
	name = "specular",
	fields = {
		{
			name = "specular",
			kind = "unorm8",
			default = "1.0",
			-- up to 2 fits
			encode = "clamp(v * 0.5, 0.0, 1.0)",
			decode = "v * 2.0",
			material = "get_specular(uv)",
			readers = {"lighting"},
		},
	},
	weather = [[
		// ice has an F0 of 0.018
		s.specular = mix(s.specular, 0.45, w.snow);
	]],
	surface_decode = [[
		s.F0 = mix(vec3(0.04 * s.specular), s.albedo, s.metallic);
	]],
}
