return {
	Loop = true,
	Layers = {
		{
			Type = "orb",
			Alpha = "fade",
			Flicker = "flicker",
			LensScale = "lens_scale",
			Size = "size",
		},
		{
			Type = "gpu_trail",
			Alpha = "fade",
			Points = 20,
			Radius = "trail_radius",
			Strength = 20,
			Texture = "orbit_trail",
		},
	},
}
