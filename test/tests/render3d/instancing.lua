local T = import("test/environment.lua")
T.SkipFile("disabled: long running and failing tests (85600db1)")

do
	return
end

local T = import("test/environment.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Material = import("goluwa/render3d/material.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local gbuffer_instancing = import("goluwa/render3d/gbuffer_instancing.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Color = import("goluwa/structs/color.lua")
local Entity = import("goluwa/entities/entity.lua")

local function attach_visual(entity, polygon3d, material)
	entity:AddComponent("visual")
	local primitive = Entity.New{
		Name = (entity:GetName() or "instancing") .. "_primitive",
		Parent = entity,
	}
	primitive:AddComponent("transform")
	local visual_primitive = primitive:AddComponent("visual_primitive")
	visual_primitive:SetPolygon3D(polygon3d)
	visual_primitive:SetMaterial(material)
	entity.visual:BuildAABB()
	entity.visual:SetUseOcclusionCulling(false)
	return entity.visual
end

T.Test3D("Graphics render3d instancing keeps distinct VMT materials out of a shared batch", function(draw)
	local sun = Entity.New{
		transform = {},
		light_sun = {
			Color = Color(1, 1, 1),
			Intensity = 1,
		},
	}
	local camera = render3d.GetCamera()
	camera:SetFOV(math.rad(90))
	camera:SetNearZ(0.1)
	camera:SetFarZ(100)
	camera:SetPosition(Vec3(0, 0, 0))
	camera:SetRotation(Quat():Identity())
	local polygon3d = Polygon3D.New()
	polygon3d:CreateCube(1)
	polygon3d:BuildBoundingBox()
	polygon3d:Upload()
	local material_a = Material.New()
	material_a.vmt_path = "materials/tests/shared.vmt"
	material_a:SetColorMultiplier(Color(1, 0, 0, 1))
	local material_b = Material.New()
	material_b.vmt_path = material_a.vmt_path
	material_b:SetColorMultiplier(Color(0, 1, 0, 1))
	local entity_a = Entity.New({Name = "instanced_material_a"})
	entity_a:AddComponent("transform")
	entity_a.transform:SetPosition(Vec3(-1.5, 0, -6))
	attach_visual(entity_a, polygon3d, material_a)
	local entity_b = Entity.New({Name = "instanced_material_b"})
	entity_b:AddComponent("transform")
	entity_b.transform:SetPosition(Vec3(1.5, 0, -6))
	attach_visual(entity_b, polygon3d, material_b)
	draw()
	local stats = gbuffer_instancing.GetStats()
	T(stats.instanced_draws)["=="](0)
	T(stats.singleton_draws)["=="](2)
	entity_a:Remove()
	entity_b:Remove()
	sun:Remove()
end)

T.Test3D("Graphics render3d instancing batches entries sharing a mesh and material", function(draw)
	local sun = Entity.New{
		transform = {},
		light_sun = {
			Color = Color(1, 1, 1),
			Intensity = 1,
		},
	}
	local camera = render3d.GetCamera()
	camera:SetFOV(math.rad(90))
	camera:SetNearZ(0.1)
	camera:SetFarZ(100)
	camera:SetPosition(Vec3(0, 0, 0))
	camera:SetRotation(Quat():Identity())
	local polygon3d = Polygon3D.New()
	polygon3d:CreateCube(1)
	polygon3d:BuildBoundingBox()
	polygon3d:Upload()
	local material = Material.New()
	local entity_a = Entity.New({Name = "instanced_shared_a"})
	entity_a:AddComponent("transform")
	entity_a.transform:SetPosition(Vec3(-1.5, 0, -6))
	attach_visual(entity_a, polygon3d, material)
	local entity_b = Entity.New({Name = "instanced_shared_b"})
	entity_b:AddComponent("transform")
	entity_b.transform:SetPosition(Vec3(1.5, 0, -6))
	attach_visual(entity_b, polygon3d, material)
	draw()
	local stats = gbuffer_instancing.GetStats()
	T(stats.instanced_draws)["=="](1)
	T(stats.singleton_draws)["=="](0)
	entity_a:Remove()
	entity_b:Remove()
	sun:Remove()
end)
