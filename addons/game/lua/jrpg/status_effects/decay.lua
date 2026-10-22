local Color = import("goluwa/structs/color.lua")
local damage = import("lua/damage.lua")
local actors = import("lua/jrpg/actors.lua")
return {
	Name = "decay",
	Label = "DCY",
	Negative = true,
	Color = Color(0.75, 0.15, 0.7, 1),
	Rate = 0.5,
	Decay = 0.1,
	Particles = {
		GravityScale = 0.2,
		SpeedMin = 0.05,
		SpeedMax = 0.3,
		LifetimeMin = 0.6,
		LifetimeMax = 1.2,
		SizeStart = 0.05,
		SizeEnd = 0,
		Drag = 4,
		Emissive = 1e5,
		ColorEnd = Color(0.05, 0, 0.08, 0),
	},
	Think = function(entity, amount, source)
		local rpg = entity.rpg

		if rpg then rpg:SetMana(math.max(rpg:GetMana() - amount * 4, 0)) end

		damage.Deal(
			entity,
			{
				Attacker = source,
				Damage = 1 + math.ceil(amount * 3),
				Type = "dark",
				Status = "decay",
				Position = actors.GetCenter(entity),
			}
		)
	end,
}
