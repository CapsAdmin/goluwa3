return {
	Name = "poison",
	Label = "PSN",
	Color = {0.35, 1, 0.3, 1},
	Think = {
		Attributes = {"poison"},
		Damage = {Base = 1, PerAmount = 4},
		Spread = {Above = 0.75, Radius = 3},
		Type = "magic",
	},
	Decay = 0.08,
	Max = 1,
	Negative = true,
	Overlay = "status_poison",
	Particles = {
		Drag = 3,
		Emissive = 150000,
		GravityScale = -0.1,
		Lifetime = {0.8, 1.6},
		Size = {Keys = {{0, 0.03}, {1, 0.07}}},
		Speed = {0.05, 0.25},
	},
	Rate = 1,
}
