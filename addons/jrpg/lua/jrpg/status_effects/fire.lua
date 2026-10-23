local Color = import("goluwa/structs/color.lua")
local damage = import("lua/damage.lua")
local actors = import("lua/actors.lua")
return {
	Name = "fire",
	Label = "BRN",
	Negative = true,
	Color = Color(1, 0.45, 0.08, 1),
	Rate = 0.4,
	Decay = 0.2,
	Particles = {
		GravityScale = -0.8,
		SpeedMin = 0.2,
		SpeedMax = 0.8,
		LifetimeMin = 0.3,
		LifetimeMax = 0.7,
		SizeStart = 0.09,
		SizeEnd = 0.01,
		Drag = 2,
		Emissive = 4e5,
		ColorEnd = Color(0.7, 0.08, 0.01, 0),
	},
	Think = function(entity, amount, source)
		damage.Deal(
			entity,
			{
				Attacker = source,
				Damage = 1 + math.ceil(amount * 5),
				Type = "fire",
				Status = "fire",
				Position = actors.GetCenter(entity),
			}
		)
	end,
}
