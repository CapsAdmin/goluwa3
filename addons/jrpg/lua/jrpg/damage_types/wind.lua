local Color = import("goluwa/structs/color.lua")
local status_effects = import("lua/jrpg/status_effects.lua")
return {
	Name = "wind",
	Color = Color(0.75, 1, 0.9, 1),
	Adjectives = {"windy", "stormy", "gusty", "drafty", "airy", "windswept"},
	Names = {"wind", "ozone", "breath", "gales"},
	Particles = {
		Spread = 70,
		GravityScale = 0,
		SpeedMin = 2,
		SpeedMax = 4,
		LifetimeMin = 0.2,
		LifetimeMax = 0.5,
		SizeStart = 0.025,
		SizeEnd = 0,
		Drag = 4,
	},
	Glow = 0.8,
	Knockback = 6,
	HitSounds = {"ambient/wind/wind_hit1.wav", "ambient/wind/wind_hit2.wav", "ambient/wind/wind_hit3.wav"},
	OnDamage = function(victim, info)
		status_effects.Add(victim, "confused", info.Damage / 200, info.Attacker)
	end,
}
