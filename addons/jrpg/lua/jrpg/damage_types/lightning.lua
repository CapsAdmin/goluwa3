local Color = import("goluwa/structs/color.lua")
local status_effects = import("lua/jrpg/status_effects.lua")
return {
	Name = "lightning",
	Color = Color(0.85, 0.88, 1, 1),
	EndColor = Color(0.4, 0.5, 1, 1),
	Adjectives = {"shocking", "electrical", "electrifying", "charged"},
	Names = {"lightning", "thunder", "zeus", "storms"},
	Particles = {
		GravityScale = 0,
		SpeedMin = 2,
		SpeedMax = 6,
		LifetimeMin = 0.05,
		LifetimeMax = 0.2,
		SizeStart = 0.02,
		SizeEnd = 0,
		Drag = 0,
	},
	Flicker = 1,
	Light = 1.3,
	HitSounds = {"ambient/energy/zap1.wav", "ambient/energy/zap2.wav", "ambient/energy/zap3.wav"},
	OnDamage = function(victim, info)
		status_effects.Set(victim, "lightning", math.max(status_effects.Get(victim, "lightning"), info.Damage / 50), info.Attacker)
	end,
}
