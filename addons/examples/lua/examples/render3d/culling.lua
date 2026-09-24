local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local Quat = import("goluwa/structs/quat.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local Material = import("goluwa/render3d/material.lua")
local Entity = import("goluwa/entities/entity.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local system = import("goluwa/system.lua")
local Visual = import("goluwa/entities/components/visual.lua")

local function spawn_sphere(pos, scale, color, use_occlusion)
	local ent = Entity.New({Name = "sphere"})
	local trans = ent:AddComponent("transform")
	trans:SetPosition(pos)
	trans:SetScale(scale or Vec3(1, 1, 1))
	local poly = Polygon3D.New()
	poly:CreateSphere(1, 16, 16)
	poly:Upload()
	local material = Material.New{
		ColorMultiplier = color or Color(1, 1, 1, 1),
	}
	ent:AddComponent("visual")
	local primitive_entity = Entity.New{Name = "sphere_primitive", Parent = ent}
	primitive_entity:AddComponent("transform")
	local visual_primitive = primitive_entity:AddComponent("visual_primitive")
	visual_primitive:SetPolygon3D(poly)
	visual_primitive:SetMaterial(material)
	ent.visual:SetUseOcclusionCulling(use_occlusion or false)
	ent.visual:BuildAABB()
	return ent
end

-- Set occlusion culling to 1 to see its effect
Visual.Library.SetOcclusionCulling(true)
-- Create a large wall to block things (Occluder)
-- We don't enable occlusion culling on it so it's always drawn first in the query pass
spawn_sphere(Vec3(0, 0, -5), Vec3(10, 10, 0.1), Color(0.2, 0.2, 0.2, 1), false)

-- Create a grid of spheres behind the wall (Occludees)
-- These use occlusion culling and should be culled on the GPU
for x = -8, 8 do
	for y = -5, 5 do
		spawn_sphere(
			Vec3(x * 1.5, y * 1.5, -15),
			Vec3(0.5, 0.5, 0.5),
			Color(math.random(), math.random(), math.random(), 1),
			true
		)
	end
end

-- Create some spheres clearly visible on the sides
spawn_sphere(Vec3(-10, 0, -10), Vec3(1, 1, 1), Color(1, 0, 0, 1), true)
spawn_sphere(Vec3(10, 0, -10), Vec3(1, 1, 1), Color(0, 1, 0, 1), true)
