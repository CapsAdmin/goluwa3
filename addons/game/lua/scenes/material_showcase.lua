local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local SphereShape = import("goluwa/physics/shapes/sphere.lua")
local assets = import("goluwa/assets.lua")
local shapes = import("lua/shapes.lua")
local example_materials = import("lua/autorun/render_3d/example_materials.lua")
local pos = Vec3(0, -0.75, 0)
local PADDING = 2.3

local function sphere(material)
	local sphere_radius = 1
	local sphere_position = (pos * PADDING):Copy()
	pos.x = pos.x + 1

	if pos.x >= 3 then
		pos.x = 0
		pos.z = pos.z + 1
	end

	shapes.Sphere{
		Name = "debug_ent",
		Position = sphere_position,
		Radius = sphere_radius,
		Material = material,
		RigidBody = false,
	}
end

for _, entry in ipairs(example_materials) do
	sphere(assets.Load(entry.path))
end

