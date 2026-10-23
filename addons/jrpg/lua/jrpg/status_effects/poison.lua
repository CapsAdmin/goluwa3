local Color = import("goluwa/structs/color.lua")
local damage = import("lua/damage.lua")
local actors = import("lua/actors.lua")
return {
	Name = "poison",
	Label = "PSN",
	Negative = true,
	Color = Color(0.35, 1, 0.3, 1),
	Rate = 1,
	Decay = 0.08,
	Particles = {
		GravityScale = -0.1,
		SpeedMin = 0.05,
		SpeedMax = 0.25,
		LifetimeMin = 0.8,
		LifetimeMax = 1.6,
		SizeStart = 0.03,
		SizeEnd = 0.07,
		Drag = 3,
		Emissive = 1.5e5,
	},
	Think = function(entity, amount, source)
		local center = actors.GetCenter(entity)
		local info = {
			Attacker = source,
			Damage = 1 + math.ceil(amount * 4),
			Type = "poison",
			Status = "poison",
			Position = center,
		}

		if amount > 0.75 then
			for _, other in ipairs(actors.Find(center, 3, entity)) do
				damage.Deal(other, table.shallow_copy(info))
			end
		end

		damage.Deal(entity, info)
	end,
}
