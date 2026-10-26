local Color = import("goluwa/structs/color.lua")
return {
	Name = "slash",
	Physical = true,
	Color = Color(1, 0.55, 0.45, 1),
	Adjectives = {"keen", "cutting", "slashing", "sharp"},
	Names = {"steel", "a blade", "a cut"},
	Particles = {
		GravityScale = 0.8,
		SpeedMin = 1,
		SpeedMax = 3.5,
		LifetimeMin = 0.25,
		LifetimeMax = 0.55,
		SizeStart = 0.035,
		SizeEnd = 0,
		Drag = 1.5,
	},
	Glow = 0.6,
	Light = 0.5,
	HitSounds = {"weapons/blade_slice_2.wav", "weapons/blade_slice_3.wav"},
}
