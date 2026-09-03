local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local Entity = import("goluwa/entities/entity.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local event = import("goluwa/event.lua")
local shapes = import("lua/shapes.lua")
local Material = import("goluwa/render3d/material.lua")
local example_materials = import("lua/autorun/render_3d/example_materials.lua")
local assets = import("goluwa/assets.lua")

local function mat(color, metallic, roughness)
	local m = Material.New()
	m:SetColorMultiplier(color)
	m:SetMetallicMultiplier(metallic)
	m:SetRoughnessMultiplier(roughness)
	return m
end

shapes.Box{
	Name = "floor_mirror",
	Position = Vec3(-6, -10, 0),
	Size = Vec3(12, 20, 24),
	Material = mat(Color(0.9, 0.9, 0.9, 1), 1, 0.0),
	Collision = false,
}
shapes.Box{
	Name = "floor_rough",
	Position = Vec3(6, -10, 0),
	Size = Vec3(12, 20, 24),
	Material = mat(Color(0.9, 0.9, 0.9, 1), 1, 0.3),
	Collision = false,
}
shapes.Box{
	Name = "wall",
	Position = Vec3(0, 3, -12),
	Size = Vec3(24, 6, 1),
	Material = mat(Color(0.8, 0.3, 0.2, 1), 0, 0.8),
	Collision = false,
}
shapes.Box{
	Position = Vec3(-4, 1.5, -4),
	Size = Vec3(3, 3, 3),
	Material = mat(Color(0.2, 0.4, 0.9, 1), 0, 0.6),
	Collision = false,
}
shapes.Sphere{
	Position = Vec3(-1, 1.5, -1),
	Radius = 1.5,
	Material = mat(Color(0.9, 0.8, 0.2, 1), 0, 0.4),
	Collision = false,
}
shapes.Box{
	Position = Vec3(4, 2, -5),
	Size = Vec3(2, 4, 2),
	Material = mat(Color(0.2, 0.8, 0.3, 1), 0, 0.5),
	Collision = false,
}
shapes.Sphere{
	Position = Vec3(6, 1, 0),
	Radius = 1,
	Material = mat(Color(1, 1, 1, 1), 1, 0.1),
	Collision = false,
}
shapes.Box{
	Position = Vec3(0, 0.5, 4),
	Size = Vec3(1, 1, 1),
	Material = mat(Color(0.9, 0.2, 0.8, 1), 0, 0.3),
	Collision = false,
}
