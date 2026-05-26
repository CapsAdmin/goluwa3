local T = import("test/environment.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Material = import("goluwa/render3d/material.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Color = import("goluwa/structs/color.lua")
local Entity = import("goluwa/ecs/entity.lua")

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
		light = {
			LightType = "sun",
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
	render3d.ResetInstancingCounters()
	draw()
	local counters = render3d.GetInstancingCounters()
	T(counters.instanced_draws)["=="](0)
	T(counters.singleton_fallback_draws)["=="](2)
	entity_a:Remove()
	entity_b:Remove()
	sun:Remove()
end)

T.Test3D("Graphics render3d instancing flushes later singleton entries after upgrading an earlier pending pair", function()
	local polygon3d = Polygon3D.New()
	polygon3d:CreateCube(1)
	polygon3d:BuildBoundingBox()
	polygon3d:Upload()
	local material_a = Material.New()
	material_a.vmt_path = "materials/tests/pair.vmt"
	local material_b = Material.New()
	material_b.vmt_path = "materials/tests/singleton.vmt"
	local world_a_1 = Matrix44():Identity()
	local world_a_2 = Matrix44():Identity()
	local world_b = Matrix44():Identity()
	render3d.ResetQueuedGBufferInstances()
	render3d.ResetInstancingCounters()
	T(render3d.QueueGBufferInstance(polygon3d, material_a, world_a_1, "pair"))["=="](true)
	T(render3d.QueueGBufferInstance(polygon3d, material_a, world_a_2, "pair"))["=="](true)
	T(render3d.QueueGBufferInstance(polygon3d, material_b, world_b, "singleton"))["=="](true)
	T(#render3d.queued_gbuffer_pending_entries)["=="](1)
	T(render3d.queued_gbuffer_pending_entries[1].material)["=="](material_b)
	T(render3d.queued_gbuffer_pending_entries[1].queue_index)["=="](1)
end)

T.Test3D("Graphics render3d instancing exposes rejection reasons", function()
	local polygon3d = Polygon3D.New()
	local material = Material.New()
	render3d.ResetInstancingCounters()
	T(render3d.CanQueueGBufferInstance(nil, material))["=="](false)
	T(render3d.CanQueueGBufferInstance(polygon3d, material))["=="](false)
	local summary = render3d.GetInstancingRejectionSummary(render3d.GetLiveInstancingCounters())
	T(summary.total)["=="](2)
	T(summary.missing_args)["=="](1)
	T(summary.missing_mesh)["=="](1)
	T(summary.missing_pipeline)["=="](0)
	T(render3d.GetRejectedInstancingAttempts(render3d.GetLiveInstancingCounters()))["=="](2)
end)

T.Test3D("Graphics render3d instancing allows vertex animated materials when the instanced pipeline is available", function()
	local polygon3d = Polygon3D.New()
	polygon3d:CreateCube(1)
	polygon3d:BuildBoundingBox()
	polygon3d:Upload()
	polygon3d:SetBranchHelperPivots{Vec3(0, 0, 0)}
	local material = Material.New()
	material:SetWindAmplitude(1)
	material:SetWindDetailAmplitude(0.25)
	render3d.ResetInstancingCounters()
	T(render3d.CanQueueGBufferInstance(polygon3d, material))["=="](true)
	local summary = render3d.GetInstancingRejectionSummary(render3d.GetLiveInstancingCounters())
	T(summary.vertex_animation)["=="](0)
	T(summary.total)["=="](0)
end)
