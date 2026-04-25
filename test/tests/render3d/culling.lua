local T = import("test/environment.lua")
local ffi = require("ffi")
local render = import("goluwa/render/render.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Material = import("goluwa/render3d/material.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Rect = import("goluwa/structs/rect.lua")
local Quat = import("goluwa/structs/quat.lua")
local Color = import("goluwa/structs/color.lua")
local Entity = import("goluwa/ecs/entity.lua")
local width, height = 512, 512

local function attach_visual_primitive(entity, poly, material)
	entity:AddComponent("visual")
	local primitive_entity = Entity.New{Name = entity:GetName() .. "_primitive", Parent = entity}
	primitive_entity:AddComponent("transform")
	local visual_primitive = primitive_entity:AddComponent("visual_primitive")
	visual_primitive:SetPolygon3D(poly)
	visual_primitive:SetMaterial(material)
	entity.visual:BuildAABB()
	return entity.visual
end

local function spawn_sphere(pos, use_occlusion)
	local ent = Entity.New({Name = "sphere"})
	local trans = ent:AddComponent("transform")
	trans:SetPosition(pos)
	local poly = Polygon3D.New()
	poly:CreateSphere(1, 16, 16)
	poly:Upload()
	local material = Material.New{
		ColorMultiplier = Color(1, 1, 1, 1),
	}
	local visual = attach_visual_primitive(ent, poly, material)
	visual:SetUseOcclusionCulling(use_occlusion or false)
	return ent, visual
end

T.Test3D("culling and occlusion", function(draw)
	local cam = render3d.GetCamera()
	cam:SetFOV(math.rad(90))
	cam:SetNearZ(0.1)
	cam:SetFarZ(100)
	cam:SetPosition(Vec3(0, 0, 0))
	cam:SetRotation(Quat(0, 0, 0, 1)) -- Looking at -Z
	T.Test3D("frustum culling front/back", function(draw)
		local ent, mdl = spawn_sphere(Vec3(0, 0, -10)) -- In front
		draw()
		T(mdl.frustum_culled)["=="](false)
		ent.transform:SetPosition(Vec3(0, 0, 10)) -- Behind
		draw()
		T(mdl.frustum_culled)["=="](true)
		ent:Remove()
	end)

	T.Test3D("frustum culling sides", function(draw)
		local ent, mdl = spawn_sphere(Vec3(20, 0, -10)) -- Far right
		draw()
		T(mdl.frustum_culled)["=="](true)
		ent.transform:SetPosition(Vec3(0, 0, -10)) -- Center
		draw()
		T(mdl.frustum_culled)["=="](false)
		ent:Remove()
	end)

	T.Test3D("occlusion culling", function(draw)
		import("goluwa/ecs/components/3d/visual.lua").Library.SetOcclusionCulling(true)
		-- Spawn a large occluder in front
		local occluder_ent, occluder_mdl = spawn_sphere(Vec3(0, 0, -5))
		occluder_ent.transform:SetScale(Vec3(5, 5, 1))
		-- Spawn a small sphere behind it
		local occludee_ent, occludee_mdl = spawn_sphere(Vec3(0, 0, -10), true)
		-- First frame: queries are executed
		draw()
		-- results are from previous frame (initially visible)
		T(occludee_mdl.using_conditional_rendering)["=="](true)
		-- Second frame: should use results from first frame
		draw()
		local stats = import("goluwa/ecs/components/3d/visual.lua").Library.GetOcclusionStats()
		--print("Occlusion stats:", stats.total, stats.with_occlusion, stats.submitted_with_conditional)
		-- We can't easily check if the GPU actually culled it, 
		-- but we can check if it was submitted with conditional rendering.
		T(occludee_mdl.using_conditional_rendering)["=="](true)
		occluder_ent:Remove()
		occludee_ent:Remove()
	end)
end)
