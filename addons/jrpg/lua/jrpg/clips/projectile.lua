return {
	Loop = true,
	Layers = {
		{
			Type = "orb",
			Size = "size",
			Alpha = "fade",
			Flicker = "flicker",
			LensScale = "lens_scale",
		},
		{
			Type = "gpu_trail",
			Points = 20,
			Texture = "orbit_trail",
			Strength = 20,
			Radius = "trail_radius",
			Alpha = "fade",
		},
	},
}
