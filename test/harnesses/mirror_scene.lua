local Entity = import("goluwa/entities/entity.lua")
local steam = import("goluwa/steam/steam.lua")
local event = import("goluwa/event.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Material = import("goluwa/render3d/material.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
steam.MountSourceGame("gmod")
import("goluwa/entities/components/visual.lua").Library.noculling = true


local poly = Polygon3D.New()
poly:CreatePlane(Vec3(0, 1.2, 2), Vec3(0, 0, 1), Vec3(1, 0, 0), Vec3(0, 1, 0), 1.6, 1.3, 1, 1, 1)
poly:Upload()
local mirror = Entity.New{Name = "mirror"}
mirror:AddComponent("transform")
mirror:AddComponent("visual")
local primitive_entity = Entity.New{Name = "mirror_primitive", Parent = mirror}
primitive_entity:AddComponent("transform")
local primitive = primitive_entity:AddComponent("visual_primitive")
primitive:SetPolygon3D(poly)
primitive:SetMaterial(
	Material.New{
		ColorMultiplier = Color(1, 1, 1, 1),
		MetallicMultiplier = 1,
		RoughnessMultiplier = 0.02,
		DoubleSided = true,
	}
)
mirror.visual:BuildAABB()
local alyx = Entity.New{Name = "alyx"}
local transform = alyx:AddComponent("transform")
transform:SetPosition(Vec3(0, 0, -1.5))
transform:SetRotation(QuatDeg3(0, 180, 0))
alyx:AddComponent("visual")
alyx.visual:SetModelPath("models/player/alyx.mdl")
local animator = alyx:AddComponent("animator")
local configured = false

event.AddListener("Update", "mirror_alyx", function()
	if configured or not animator.skeleton then return end

	configured = true
	local clip = animator.skeleton.ClipsByName.run_all or animator.skeleton.ClipsByName.walk_all
	animator:SetSequence(clip.Name)
	animator:SetPoseParameterByName("move_x", 1)
	animator:SetSpeed(1)
end)

_G.MIRROR_ALYX = alyx

local function colored_box(name, position, color)
	local box_poly = Polygon3D.New()
	box_poly:CreateCube(0.3, 1)
	box_poly:Upload()
	local box = Entity.New{Name = name}
	box:AddComponent("transform"):SetPosition(position)
	box:AddComponent("visual")
	local child = Entity.New{Name = name .. "_primitive", Parent = box}
	child:AddComponent("transform")
	local box_primitive = child:AddComponent("visual_primitive")
	box_primitive:SetPolygon3D(box_poly)
	box_primitive:SetMaterial(
		Material.New{
			ColorMultiplier = color,
			MetallicMultiplier = 0,
			RoughnessMultiplier = 0.8,
		}
	)
	box.visual:BuildAABB()
	return box
end

colored_box("red_box", Vec3(0.9, 0.3, -1.5), Color(1, 0.05, 0.05, 1))
colored_box("green_box", Vec3(-0.9, 0.3, -1.5), Color(0.05, 1, 0.05, 1))
