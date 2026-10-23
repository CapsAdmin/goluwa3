local Color = import("goluwa/structs/color.lua")
local status_effects = import("lua/jrpg/status_effects.lua")
return {
	Name = "fire",
	Surface = {Kind = "fire", Radius = 1.0, Amount = 0.9},
	Color = Color(1, 0.49, 0.1, 1),
	EndColor = Color(0.8, 0.12, 0.02, 1),
	Adjectives = {"hot", "molten", "burning", "flaming", "scorching"},
	Names = {"fire", "flames", "embers"},
	Particles = {
		GravityScale = -0.6,
		SpeedMin = 0.1,
		SpeedMax = 0.8,
		LifetimeMin = 0.3,
		LifetimeMax = 0.7,
		SizeStart = 0.07,
		SizeEnd = 0.01,
		Drag = 2,
	},
	Glow = 1.3,
	Light = 1.5,
	HitSounds = {"ambient/fire/mtov_flame2.wav", "ambient/fire/ignite.wav"},
	OnDamage = function(victim, info)
		status_effects.Remove(victim, "frozen")
		status_effects.Add(victim, "fire", info.Damage / 100, info.Attacker)
	end,
}
