return {
	name = "decal_receiver",
	category = "Decal",
	params = {
		{
			name = "DecalReceiver",
			default = 0.0,
			getter = "get_decal_receiver",
			callback = "InvalidateRayMaterial",
		},
	},
	fields = {
		{
			name = "decal_receiver",
			kind = "unorm4",
			default = "0.0",
			material = "get_decal_receiver() / 15.0",
		},
	},
}
