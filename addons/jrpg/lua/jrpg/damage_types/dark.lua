local Color = import("goluwa/structs/color.lua")
local status_effects = import("lua/jrpg/status_effects.lua")
return {
	Name = "dark",
	Overlay = "status_decay",
	Color = Color(1, 0.2, 0.8, 1),
	EndColor = Color(0.15, 0, 0.2, 1),
	Adjectives = {
		"eerie",
		"ghastly",
		"cursed",
		"evil",
		"darkened",
		"haunted",
		"corrupt",
		"malicious",
		"unpleasant",
		"hateful",
		"wrathful",
	},
	Names = {"misery", "sin", "suffering", "darkness", "hades", "corruption"},
	Particles = {
		GravityScale = 0,
		SpeedMin = 0.2,
		SpeedMax = 1,
		LifetimeMin = 0.4,
		LifetimeMax = 0.9,
		SizeStart = 0.06,
		SizeEnd = 0,
		Drag = 5,
	},
	Glow = 1.2,
	HitSounds = {"ambient/levels/citadel/portal_beam_shoot5.wav"},
	OnDamage = function(victim, info)
		status_effects.Add(victim, "decay", info.Damage / 150, info.Attacker)
	end,
}
