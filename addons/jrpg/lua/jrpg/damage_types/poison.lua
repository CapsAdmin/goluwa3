local Color = import("goluwa/structs/color.lua")
local status_effects = import("lua/jrpg/status_effects.lua")
return {
	Name = "poison",
	Overlay = "status_poison",
	Color = Color(0.4, 1, 0.35, 1),
	EndColor = Color(0.15, 0.45, 0.05, 1),
	Adjectives = {"poisonous", "venomous", "toxic", "infected", "diseased"},
	Names = {"poison", "venom", "infection", "illness", "sickness"},
	Particles = {
		GravityScale = -0.1,
		SpeedMin = 0.05,
		SpeedMax = 0.4,
		LifetimeMin = 0.6,
		LifetimeMax = 1.4,
		SizeStart = 0.04,
		SizeEnd = 0.08,
		Drag = 3,
	},
	Glow = 0.8,
	HitSounds = {
		"ambient/levels/canals/toxic_slime_sizzle2.wav",
		"ambient/levels/canals/toxic_slime_sizzle3.wav",
	},
	OnDamage = function(victim, info)
		status_effects.Add(victim, "poison", info.Damage / 100, info.Attacker)
	end,
}
