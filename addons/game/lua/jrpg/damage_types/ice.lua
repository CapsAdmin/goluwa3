local Color = import("goluwa/structs/color.lua")
local status_effects = import("lua/jrpg/status_effects.lua")
return {
	Name = "ice",
	Color = Color(0.6, 0.82, 1, 1),
	EndColor = Color(0.9, 0.97, 1, 1),
	Adjectives = {"cold", "frozen", "freezing", "chilled", "iced", "arctic", "frosted"},
	Names = {"ice", "glacier", "snow", "frost"},
	Particles = {
		GravityScale = 0.6,
		SpeedMin = 0.3,
		SpeedMax = 1.2,
		LifetimeMin = 0.4,
		LifetimeMax = 1,
		SizeStart = 0.035,
		SizeEnd = 0.015,
		Drag = 1,
	},
	HitSounds = {"physics/glass/glass_impact_bullet1.wav", "physics/glass/glass_impact_bullet4.wav"},
	OnDamage = function(victim, info)
		status_effects.Remove(victim, "fire")
		status_effects.Add(victim, "frozen", info.Damage / 100, info.Attacker)
	end,
}
