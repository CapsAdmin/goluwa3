local system = import("goluwa/system.lua")
local test_scene = import("goluwa/render3d/test_scene.lua")
local surface_effects = import("goluwa/render3d/surface_effects.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local demo = {}
local WOOD = shapes.Material{
	Color = Color(0.42, 0.28, 0.16, 1),
	Roughness = 0.75,
	Metallic = 0,
	Flammability = 1,
}
local PLANKS = shapes.Material{
	Color = Color(0.55, 0.4, 0.25, 1),
	Roughness = 0.6,
	Metallic = 0,
	Flammability = 1,
}
local GRASS = shapes.Material{
	Color = Color(0.18, 0.3, 0.07, 1),
	Roughness = 0.95,
	Metallic = 0,
	Flammability = 0.7,
}
local STONE = shapes.Material{
	Color = Color(0.42, 0.41, 0.4, 1),
	Roughness = 0.8,
	Metallic = 0,
	Flammability = 0.02,
}
test_scene.Reset{
	sun = {elevation = test_scene.GetNumber("SURFACE_EFFECTS_SUN", 30), azimuth = 210},
}
test_scene.Ground{size = 120, material = GRASS}
test_scene.Box{
	name = "path",
	pos = Vec3(0, 0.01, 0),
	size = Vec3(2.5, 0.04, 30),
	material = STONE,
}
test_scene.Room{
	pos = Vec3(-6, 0, 4),
	size = Vec3(4, 2.6, 3.5),
	thickness = 0.15,
	material = PLANKS,
	openings = {{wall = "+x", x = 0, y = 1, width = 1.1, height = 2}},
}

for i, pos in ipairs{Vec3(-3.2, 0.4, 1), Vec3(-3.6, 0.4, 2.1), Vec3(-3.3, 1.2, 1.4)} do
	test_scene.Box{name = "crate" .. i, pos = pos, size = Vec3(0.8, 0.8, 0.8), material = WOOD}
end

test_scene.Box{
	name = "stone_wall",
	pos = Vec3(5, 0.75, 3),
	size = Vec3(0.5, 1.5, 6),
	material = STONE,
}
test_scene.Box{
	name = "bench",
	pos = Vec3(3, 0.45, -2),
	size = Vec3(2, 0.1, 0.6),
	material = PLANKS,
}
test_scene.Box{
	name = "bench_leg_a",
	pos = Vec3(2.2, 0.2, -2),
	size = Vec3(0.1, 0.4, 0.5),
	material = WOOD,
}
test_scene.Box{
	name = "bench_leg_b",
	pos = Vec3(3.8, 0.2, -2),
	size = Vec3(0.1, 0.4, 0.5),
	material = WOOD,
}

function demo.Start()
	surface_effects.Clear()
	surface_effects.Apply("fire", Vec3(-3.4, 0, 0.4), 1.2, 1)
	surface_effects.Apply("frost", Vec3(0, 0, -3), 2.5, 1)
	surface_effects.Apply("frost", Vec3(4.75, 0.75, 1.5), 1.2, 1, Vec3(-1, 0, 0))
	surface_effects.Apply("poison", Vec3(5, 0, -5), 2, 1)
end

test_scene.WhenReady(demo.Start)
return demo
