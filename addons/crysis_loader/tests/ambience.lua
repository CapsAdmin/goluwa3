local T = import("test/environment.lua")
local Ambience = import("lua/components/cry_ambience.lua")

T.Test("Cry ambience areas are zero inside and measure the distance outside", function()
	local shape = {
		kind = "shape",
		points = {{0, 0}, {10, 0}, {10, 10}, {0, 10}},
		bottom = 0,
		top = 5,
	}
	T(Ambience.GetAreaDistance(shape, 5, 1, 5))["=="](0)
	T(Ambience.GetAreaDistance(shape, 13, 1, 5))["~"](3, 0.0001)
	T(Ambience.GetAreaDistance(shape, 5, 9, 5))["~"](4, 0.0001)
	local unbounded = {kind = "shape", points = shape.points, bottom = 0}
	T(Ambience.GetAreaDistance(unbounded, 5, 1000, 5))["=="](0)
	local box = {kind = "box", origin = {0, 0, 0}, edges = {{4, 0, 4}, {0, 3, 0}, {-2, 0, 2}}}
	T(Ambience.GetAreaDistance(box, 1, 1, 1))["=="](0)
	T(Ambience.GetAreaDistance(box, 1, 5, 1))["~"](2, 0.0001)
	local sphere = {kind = "sphere", center = {0, 0, 0}, radius = 2}
	T(Ambience.GetAreaDistance(sphere, 0, 1, 0))["=="](0)
	T(Ambience.GetAreaDistance(sphere, 5, 0, 0))["~"](3, 0.0001)
end)
