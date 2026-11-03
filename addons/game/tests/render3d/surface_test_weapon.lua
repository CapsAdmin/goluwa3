local T = import("test/environment.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local surface_conditions = import("goluwa/render3d/surface_conditions.lua")
local weapon_effects = import("lua/weapon_effects.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")

T.Test3D("the surface test weapon lists the registered conditions and applies and clears them", function(draw)
	local names = weapon_effects.GetSurfaceConditionNames()
	T(not not (table.has_value(names, "fire") and table.has_value(names, "frost") and table.has_value(names, "water")))["=="](true)
	T(#names)["=="](#surface_conditions.kinds)
	local ground = shapes.Box{
		Position = Vec3(0, -0.5, 0),
		Size = Vec3(10, 1, 10),
		Material = shapes.Material{Color = Color(0.6, 0.5, 0.4, 1), Roughness = 0.8, Metallic = 0, Flammability = 1},
		Collision = false,
		RigidBody = false,
	}
	draw()
	surface_conditions.Clear()
	weapon_effects.TestSurfaceCondition("frost", Vec3(0, 0, 0), Vec3(0, 1, 0), 1, 1)
	T(surface_conditions.GetCellCount())[">"](0)
	T(surface_conditions.Query(Vec3(0, 0, 0), 1, "frost"))[">"](0)
	weapon_effects.ClearSurfaceConditions()
	T(surface_conditions.GetCellCount())["=="](0)
	ground:Remove()
end)
