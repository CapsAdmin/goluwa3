return {
	Loop = true,
	Layers = {
		{
			Type = "slash",
			Alpha = "v.release",
			Overlay = "magic_generic",
			OverlayConfig = {FadeIn = 0.05, FadeOut = 0.05, Scale = 1.5, UVScale = {0.8, 1}, UVStretch = 40},
			Points = 18,
			Strength = 0.1,
		},
		{
			Type = "gpu_trail",
			Alpha = "v.release",
			Points = 48,
			Radius = 0.03,
			Strength = 6,
			Taper = 0.8,
			Texture = "trail",
		},
		{
			Type = "emitter",
			At = "tip",
			Emitter = "melee_sparks",
			Inputs = {Tint = "color"},
		},
	},
	Preview = {
		Drive = {Type = "blade", From = 160, Length = 1.1, Reach = 0.3, Time = 0.5, To = 20},
		Exposure = "night",
		Params = {base = "$chest", color = {1, 0.6, 0.2, 1}, position = "$chest", tip = "$chest"},
		Release = 1,
		Stage = "gizmo",
	},
}
