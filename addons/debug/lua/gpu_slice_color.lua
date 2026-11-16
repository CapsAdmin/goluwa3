local Color = import("goluwa/structs/color.lua")
return function(index, shade)
	local c = Color.FromHSV(index * 0.381966, 0.62 - shade * 0.25, 0.95 - shade * 0.35)
	return c.r, c.g, c.b
end
