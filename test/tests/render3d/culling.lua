local T = import("test/environment.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Material = import("goluwa/render3d/material.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local Texture = import("goluwa/render/texture.lua")
local Visual = import("goluwa/ecs/components/3d/visual.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Color = import("goluwa/structs/color.lua")
local Entity = import("goluwa/ecs/entity.lua")

local function attach_visual(entity, polygon3d, material)
	entity:AddComponent("visual")
	local primitive = Entity.New{
		Name = (entity:GetName() or "culling") .. "_primitive",
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

local function build_cube_polygon()
	local polygon3d = Polygon3D.New()
	polygon3d:CreateCube(1)
	polygon3d:BuildBoundingBox()
	polygon3d:Upload()
	return polygon3d
end

local function configure_camera()
	local camera = render3d.GetCamera()
	camera:SetFOV(math.rad(90))
	camera:SetNearZ(0.1)
	camera:SetFarZ(100)
	camera:SetPosition(Vec3(0, 0, 0))
	camera:SetRotation(Quat():Identity())
	return camera
end

local function visible_lookup(components)
	local lookup = {}

	for _, component in ipairs(components) do
		lookup[component] = true
	end

	return lookup
end

local function list_contains(list, value)
	for _, item in ipairs(list) do
		if item == value then return true end
	end

	return false
end

T.Test("Graphics ecs config-created visual components run OnAdd registration", function()
	local entity = Entity.New{
		Name = "config_visual_registration",
		transform = {},
		visual = {},
	}
	T(list_contains(Visual.Library.shadow_casters, entity.visual))["=="](true)
	entity:Remove()
	T(list_contains(Visual.Library.shadow_casters, entity.visual))["=="](false)
end)

T.Test3D("Graphics render3d culling acceleration returns only frustum and distance visible visuals", function()
	local sun = Entity.New{
		transform = {},
		light = {
			LightType = "sun",
			Color = Color(1, 1, 1),
			Intensity = 1,
		},
	}
	configure_camera()
	local polygon3d = build_cube_polygon()
	local material = Material.New()
	local front = Entity.New({Name = "front_visual"})
	front:AddComponent("transform")
	front.transform:SetPosition(Vec3(0, 0, -6))
	attach_visual(front, polygon3d, material)
	local behind = Entity.New({Name = "behind_visual"})
	behind:AddComponent("transform")
	behind.transform:SetPosition(Vec3(0, 0, 6))
	attach_visual(behind, polygon3d, material)
	local far = Entity.New({Name = "far_visual"})
	far:AddComponent("transform")
	far.transform:SetPosition(Vec3(0, 0, -20))
	attach_visual(far, polygon3d, material)
	far.visual:SetCullDistance(2)
	Visual.Library.InvalidateSceneAcceleration()
	local visible = visible_lookup(Visual.Library.GetVisibleVisuals())
	T(visible[front.visual])["=="](true)
	T(visible[behind.visual])["=="](nil)
	T(visible[far.visual])["=="](nil)
	front:Remove()
	behind:Remove()
	far:Remove()
	sun:Remove()
end)

T.Test3D("Graphics render3d culling acceleration invalidates after transform moves", function()
	local sun = Entity.New{
		transform = {},
		light = {
			LightType = "sun",
			Color = Color(1, 1, 1),
			Intensity = 1,
		},
	}
	configure_camera()
	local polygon3d = build_cube_polygon()
	local material = Material.New()
	local entity = Entity.New({Name = "moving_visual"})
	entity:AddComponent("transform")
	entity.transform:SetPosition(Vec3(0, 0, 6))
	attach_visual(entity, polygon3d, material)
	Visual.Library.InvalidateSceneAcceleration()
	local initially_visible = visible_lookup(Visual.Library.GetVisibleVisuals())
	T(initially_visible[entity.visual])["=="](nil)
	entity.transform:SetPosition(Vec3(0, 0, -6))
	local moved_visible = visible_lookup(Visual.Library.GetVisibleVisuals())
	T(moved_visible[entity.visual])["=="](true)
	entity:Remove()
	sun:Remove()
end)

T.Test3D("Graphics render3d shadow acceleration filters safe casters and preserves displaced fallback casters", function()
	local polygon3d = build_cube_polygon()
	local material = Material.New()
	local displaced_material = Material.New()
	displaced_material:SetHeightTexture(Texture.GetFallback())
	displaced_material:SetHeightScale(1)
	local inside = Entity.New({Name = "shadow_inside"})
	inside:AddComponent("transform")
	inside.transform:SetPosition(Vec3(0, 0, -6))
	attach_visual(inside, polygon3d, material)
	local outside = Entity.New({Name = "shadow_outside"})
	outside:AddComponent("transform")
	outside.transform:SetPosition(Vec3(50, 0, -6))
	attach_visual(outside, polygon3d, material)
	local displaced = Entity.New({Name = "shadow_displaced"})
	displaced:AddComponent("transform")
	displaced.transform:SetPosition(Vec3(60, 0, -6))
	attach_visual(displaced, polygon3d, displaced_material)
	Visual.Library.InvalidateSceneAcceleration()
	local shadow_map = {
		IsWorldAABBVisible = function(self, cascade_idx, world_aabb)
			return world_aabb.min_x < 10
		end,
		IsWorldAABBTooSmall = function()
			return false
		end,
		UsesTessellatedMaterial = function()
			return false
		end,
	}
	local visible = visible_lookup(Visual.Library.GetShadowVisibleVisuals(shadow_map, 1))
	T(visible[inside.visual])["=="](true)
	T(visible[outside.visual])["=="](nil)
	T(visible[displaced.visual])["=="](true)
	inside:Remove()
	outside:Remove()
	displaced:Remove()
end)

T.Test3D("Graphics render3d shadow acceleration invalidates after transform moves", function()
	local polygon3d = build_cube_polygon()
	local material = Material.New()
	local entity = Entity.New({Name = "moving_shadow"})
	entity:AddComponent("transform")
	entity.transform:SetPosition(Vec3(50, 0, -6))
	attach_visual(entity, polygon3d, material)
	Visual.Library.InvalidateSceneAcceleration()
	local shadow_map = {
		IsWorldAABBVisible = function(self, cascade_idx, world_aabb)
			return world_aabb.min_x < 10
		end,
		IsWorldAABBTooSmall = function()
			return false
		end,
		UsesTessellatedMaterial = function()
			return false
		end,
	}
	local initially_visible = visible_lookup(Visual.Library.GetShadowVisibleVisuals(shadow_map, 1))
	T(initially_visible[entity.visual])["=="](nil)
	entity.transform:SetPosition(Vec3(0, 0, -6))
	local moved_visible = visible_lookup(Visual.Library.GetShadowVisibleVisuals(shadow_map, 1))
	T(moved_visible[entity.visual])["=="](true)
	entity:Remove()
end)

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
