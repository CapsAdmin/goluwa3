local Color = import("goluwa/structs/color.lua")
return {
	Name = "generic",
	DisplayName = "Arcane",
	Color = Color(0.9, 0.92, 1, 1),
	Adjectives = {"arcane", "mystic", "ethereal", "astral"},
	Names = {"the arcane", "mysticism", "the aether"},
	Particles = {GravityScale = 0.3, SpeedMin = 0.5, SpeedMax = 2},
	HitSounds = {"weapons/physcannon/energy_disintegrate4.wav"},
}
