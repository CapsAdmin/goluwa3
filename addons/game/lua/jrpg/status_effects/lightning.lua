local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local damage = import("lua/damage.lua")
local actors = import("lua/jrpg/actors.lua")
return {
	Name = "lightning",
	Label = "SHK",
	Negative = true,
	Color = Color(0.8, 0.85, 1, 1),
	Rate = 0.15,
	Decay = 0.25,
	Flicker = 1,
	Particles = {
		GravityScale = 0,
		SpeedMin = 1.5,
		SpeedMax = 4,
		LifetimeMin = 0.04,
		LifetimeMax = 0.12,
		SizeStart = 0.015,
		SizeEnd = 0,
		Drag = 0,
		Emissive = 6e5,
	},
	CanAttack = function(amount)
		return math.random() > amount * 0.5
	end,
	Think = function(entity, amount, source)
		if math.random() ^ amount <= 0.8 then return end

		local center = actors.GetCenter(entity)
		local info = {
			Attacker = source,
			Damage = 1 + math.ceil(amount * 2),
			Type = "lightning",
			Status = "lightning",
			Position = center,
			Force = Vec3(math.randomf(-1, 1), math.randomf(0, 1), math.randomf(-1, 1)) * amount * 3,
		}

		if amount > 0.75 then
			for _, other in ipairs(actors.Find(center, 3, entity)) do
				damage.Deal(other, table.shallow_copy(info))
			end
		end

		damage.Deal(entity, info)
	end,
}
