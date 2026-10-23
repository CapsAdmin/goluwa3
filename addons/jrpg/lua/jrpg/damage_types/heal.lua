local Color = import("goluwa/structs/color.lua")
local status_effects = import("lua/jrpg/status_effects.lua")
return {
	Name = "heal",
	Color = Color(0.55, 1, 0.6, 1),
	EndColor = Color(0.9, 1, 0.9, 1),
	Adjectives = {"healing", "curative", "medicinal", "soothing"},
	Names = {"health", "wellbeing", "healthiness", "recovery"},
	Particles = {
		GravityScale = -0.3,
		SpeedMin = 0.1,
		SpeedMax = 0.5,
		LifetimeMin = 0.6,
		LifetimeMax = 1.2,
		SizeStart = 0.04,
		SizeEnd = 0,
		Drag = 2,
	},
	Heals = true,
	HitSounds = {"items/smallmedkit1.wav"},
	OnDamage = function(victim, info)
		for _, name in ipairs{"poison", "decay", "fire", "frozen", "confused"} do
			status_effects.Remove(victim, name)
		end
	end,
}
