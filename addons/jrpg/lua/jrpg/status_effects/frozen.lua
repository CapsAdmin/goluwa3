local Color = import("goluwa/structs/color.lua")
local SOLID = 0.75
return {
	Name = "frozen",
	Label = "FRZ",
	Negative = true,
	Overlay = "status_frozen",
	Color = Color(0.6, 0.85, 1, 1),
	Decay = 0.12,
	Particles = {
		GravityScale = 0.15,
		SpeedMin = 0.02,
		SpeedMax = 0.15,
		LifetimeMin = 0.8,
		LifetimeMax = 1.6,
		SizeStart = 0.02,
		SizeEnd = 0.01,
		Drag = 3,
		Emissive = 1e5,
	},
	Solid = SOLID,
	Speed = function(amount)
		if amount >= SOLID then return 0 end

		return 1 - amount
	end,
	CanAttack = function(amount)
		return amount < SOLID
	end,
	AnimationSpeed = function(amount)
		if amount >= SOLID then return 0 end

		return 1 - amount * 0.8
	end,
}
