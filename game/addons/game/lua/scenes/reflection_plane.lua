local Vec3 = import("goluwa/structs/vec3.lua")
local shapes = import("lua/shapes.lua")
local reflection_mat = shapes.Material{
	Albedo = [[
		return vec4(0.8, 0.9, 1.0, 1.0);
	]],
	Metallic = "return vec4(1.0);",
	Roughness = "return vec4(0.0);",
}
shapes.Sphere{
	Name = "reflection_plane",
	Collision = false,
	Position = Vec3(17.9, -243.3, 1.1),
	Scale = Vec3(100, 1, 100),
	Radius = 1,
	Material = reflection_mat,
}
