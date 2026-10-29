local Color = import("goluwa/structs/color.lua")
local status_effects = import("lua/jrpg/status_effects.lua")
return {
	Name = "water",
	Color = Color(0.25, 0.55, 1, 1),
	EndColor = Color(0.6, 0.85, 1, 1),
	Adjectives = {"soggy", "doused", "soaked", "rainy", "misty", "wet"},
	Names = {"water", "rain", "aqua", "the tide"},
	Particles = {
		GravityScale = 1,
		SpeedMin = 0.5,
		SpeedMax = 2,
		LifetimeMin = 0.4,
		LifetimeMax = 0.9,
		SizeStart = 0.035,
		SizeEnd = 0.02,
		Drag = 0.5,
	},
	Knockback = 2,
	HitSounds = {"ambient/water/wave1.wav", "ambient/water/wave2.wav", "ambient/water/wave3.wav"},
	OnDamage = function(victim, info)
		status_effects.Remove(victim, "fire")
	end,
}
