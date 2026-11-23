return {
	name = "diffuse_roughness",
	category = "Diffuse",
	params = {
		{
			name = "DiffuseRoughness",
			default = 0.0,
			getter = "get_diffuse_roughness",
			callback = "InvalidateRayMaterial",
		},
	},
	fields = {
		{
			name = "diffuse_roughness",
			kind = "unorm4",
			default = "0.0",
			material = "get_diffuse_roughness()",
			readers = {"lighting"},
		},
	},
}
