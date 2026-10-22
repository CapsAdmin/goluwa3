local Color = import("goluwa/structs/color.lua")
return {
	Name = "confused",
	Label = "CNF",
	Negative = true,
	Color = Color(1, 0.95, 0.4, 1),
	Decay = 0.2,
	Orbit = true,
	CanAttack = function(amount)
		return math.random() > amount * 0.6
	end,
	Wobble = function(amount, time)
		return math.sin(time * 3.1) * amount * 1.4 + math.sin(time * 7.3) * amount * 0.5
	end,
}
