local Color = import("goluwa/structs/color.lua")
return {
	Name = "holy",
	Color = Color(1, 0.82, 0.55, 1),
	EndColor = Color(1, 1, 0.9, 1),
	Adjectives = {"angelic", "divine", "spiritual", "sublime", "celestial", "spirited"},
	Names = {"light", "holiness", "grace"},
	Particles = {
		GravityScale = -0.15,
		SpeedMin = 0.1,
		SpeedMax = 0.6,
		LifetimeMin = 0.6,
		LifetimeMax = 1.4,
		SizeStart = 0.03,
		SizeEnd = 0,
		Drag = 2,
	},
	Glow = 1.4,
	Light = 1.5,
	HitSounds = {"ambient/levels/coast/coastbird4.wav", "ambient/levels/coast/coastbird6.wav"},
	OnDamage = function(victim, info)
		local attacker = info.Attacker

		if attacker and attacker ~= victim and attacker:IsValid() and attacker.health then
			attacker.health:Heal(info.Damage * 0.25)
		end
	end,
}
