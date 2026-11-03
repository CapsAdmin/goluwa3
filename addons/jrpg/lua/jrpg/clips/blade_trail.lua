return {
	Loop = true,
	Layers = {
		{
			Type = "slash",
			Points = 18,
			Strength = 0.1,
			Overlay = "magic_generic",
			OverlayConfig = {FadeIn = 0.05, FadeOut = 0.05, Scale = 1.5, UVScale = {0.8, 1}, UVStretch = 40},
			Alpha = "v.release",
		},
		{
			Type = "gpu_trail",
			Points = 48,
			Strength = 6,
			Radius = 0.03,
			Taper = 0.8,
			Texture = "trail",
			Alpha = "v.release",
		},
		{
			Type = "emitter",
			Emitter = "melee_sparks",
			At = "tip",
			Inputs = {Tint = "color"},
		},
	},
	Preview = {
		Stage = "gizmo",
		Exposure = "night",
		Release = 1,
		Params = {color = {1, 0.6, 0.2, 1}, base = "$chest", tip = "$chest", position = "$chest"},
		Drive = {Type = "blade", Time = 0.5, Length = 1.1, Reach = 0.3, From = 160, To = 20},
	},
}
