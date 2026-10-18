local T = import("test/environment.lua")
local ffi = require("ffi")
local bit = require("bit")
local vk = import("goluwa/bindings/vk.lua")
local objects = import("goluwa/objects/objects.lua")
local event = import("goluwa/event.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local Material = import("goluwa/render3d/material.lua")
local render = import("goluwa/render/render.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local gbuffer_layout = import("goluwa/render3d/gbuffer_layout.lua")
local gbuffer_instancing = import("goluwa/render3d/gbuffer_instancing.lua")
local Visual = import("goluwa/entities/components/visual.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Color = import("goluwa/structs/color.lua")
local Entity = import("goluwa/entities/entity.lua")
local pvars = import("goluwa/cli/pvars.lua")

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

local function add_visual_primitive(entity, polygon3d, material, name)
	local primitive = Entity.New{
		Name = name or (entity:GetName() or "culling") .. "_primitive",
		Parent = entity,
	}
	primitive:AddComponent("transform")
	local visual_primitive = primitive:AddComponent("visual_primitive")
	visual_primitive:SetPolygon3D(polygon3d)
	visual_primitive:SetMaterial(material)
	return primitive, visual_primitive
end

local function build_cube_polygon()
	local polygon3d = Polygon3D.New()
	shapes.BuildCube(polygon3d, 1)
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

local function visible_lookup(components, visible_entry_index_ptr, visible_entry_count)
	local lookup = {}

	if visible_entry_index_ptr then
		for i = 0, (visible_entry_count or 0) - 1 do
			local record = components[tonumber(visible_entry_index_ptr[i]) + 1]
			local resolved = record and record.component or nil

			if resolved then lookup[resolved] = true end
		end

		return lookup
	end

	for _, component in ipairs(components) do
		local resolved = component and component.component or component

		if resolved then lookup[resolved] = true end
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
		light_sun = {
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
		light_sun = {
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

do
	local RADII_PER_UNIT = 1 / math.sqrt(3)

	local function build_lod_visual(name, distance)
		local material = Material.New()
		local entity = Entity.New({Name = name})
		entity:AddComponent("transform")
		entity.transform:SetPosition(Vec3(0, 0, -distance))
		attach_visual(entity, build_cube_polygon(), material)
		local coarse = build_cube_polygon()
		coarse:SetLODLevel(1)
		coarse:SetLODDistance(10)
		add_visual_primitive(entity, coarse, material, name .. "_coarse")
		entity.visual:BuildAABB()
		Visual.Library.InvalidateSceneAcceleration()
		Visual.Library.GetVisibleVisuals()
		return entity
	end

	local function build_colored_lod_visual(name, distance)
		local entity = Entity.New({Name = name})
		entity:AddComponent("transform")
		entity.transform:SetPosition(Vec3(0, 0, -distance))
		attach_visual(entity, build_cube_polygon(), Material.New{ColorMultiplier = Color(1, 0, 0, 1)})
		local coarse = build_cube_polygon()
		coarse:SetLODLevel(1)
		coarse:SetLODDistance(10)
		add_visual_primitive(entity, coarse, Material.New{ColorMultiplier = Color(0, 1, 0, 1)}, name .. "_coarse")
		entity.visual:BuildAABB()
		return entity
	end

	-- the level of detail the scene store draws in the main view: red is the fine level, green the coarse one
	local function drawn_level(draw)
		configure_camera()

		for _ = 1, 4 do
			draw()
		end

		local size = render.GetRenderImageSize()
		local r, g = gbuffer_layout.GetTexture("albedo"):GetPixel(math.floor(size.x / 2), math.floor(size.y / 2))
		return r > g and 0 or 1
	end

	T.Test3D("Graphics render3d the scene store draws the level of detail by distance", function(draw)
		local near = build_colored_lod_visual("scene_draw_lod_near", 8)
		T(drawn_level(draw))["=="](0)
		near:Remove()
		local far = build_colored_lod_visual("scene_draw_lod_far", 40)
		T(drawn_level(draw))["=="](1)
		far:Remove()
	end)

	T.Test3D("Graphics render3d the scene store draws lod_level over the distance and lod_scale moves the switch", function(draw)
		local near = build_colored_lod_visual("scene_draw_lod_forced", 8)
		pvars.SetSession("lod_level", 1)
		T(drawn_level(draw))["=="](1)
		pvars.SetSession("lod_level", -1)
		near:Remove()
		local far = build_colored_lod_visual("scene_draw_lod_scaled", 40)
		pvars.SetSession("lod_scale", 4)
		T(drawn_level(draw))["=="](0)
		pvars.SetSession("lod_scale", 1)
		far:Remove()
	end)

	T.Test3D("Graphics render3d visual builds the bvh from one fixed level and never a billboard", function()
		local entity = build_lod_visual("lod_bvh", 8)
		local material = Material.New()
		local billboard = build_cube_polygon()
		billboard:SetLODLevel(2)
		billboard:SetLODDistance(20)
		billboard:SetLODBillboard(true)
		add_visual_primitive(entity, billboard, material, "lod_bvh_billboard")
		entity.visual:BuildAABB()
		T(#entity.visual:GetLODRenderEntries())["=="](3)
		T(#entity.visual:GetBVHRenderEntries())["=="](1)
		T(entity.visual:GetBVHRenderEntries()[1].lod_level)["=="](0)
		pvars.SetSession("lod_bvh_level", 1)
		T(entity.visual:GetBVHRenderEntries()[1].lod_level)["=="](1)
		pvars.SetSession("lod_bvh_level", 9)
		local entries = entity.visual:GetBVHRenderEntries()
		T(#entries)["=="](1)
		T(entries[1].lod_level)["=="](1)
		T(entries[1].lod_billboard)["~="](true)
		pvars.SetSession("lod_bvh_level", 0)
		entity:Remove()
		Visual.Library.InvalidateSceneAcceleration()
	end)

	T.Test3D("Graphics render3d visual shows the level of the camera distance and a billboard as the level before it", function()
		local entity = build_lod_visual("lod_at", 8)
		local material = Material.New()
		local billboard = build_cube_polygon()
		billboard:SetLODLevel(2)
		billboard:SetLODDistance(20)
		billboard:SetLODBillboard(true)
		add_visual_primitive(entity, billboard, material, "lod_at_billboard")
		entity.visual:BuildAABB()
		local position = entity.transform:GetPosition()
		local unit = math.sqrt(3)
		local near = entity.visual:GetLODEntriesAt(position + Vec3(0, 0, 4 * unit))
		T(#near)["=="](1)
		T(near[1].lod_level)["=="](0)
		local middle = entity.visual:GetLODEntriesAt(position + Vec3(0, 0, 14 * unit))
		T(#middle)["=="](1)
		T(middle[1].lod_level)["=="](1)
		local far = entity.visual:GetLODEntriesAt(position + Vec3(0, 0, 60 * unit))
		T(#far)["=="](1)
		T(far[1].lod_level)["=="](1)
		T(far[1].lod_billboard ~= true)["=="](true)
		pvars.SetSession("lod_level", 0)
		T(entity.visual:GetLODEntriesAt(position + Vec3(0, 0, 60 * unit))[1].lod_level)["=="](0)
		pvars.SetSession("lod_level", -1)
		entity:Remove()
		Visual.Library.InvalidateSceneAcceleration()
	end)

	T.Test3D("Graphics render3d visual keeps only the most detailed level in its render entries", function()
		local entity = build_lod_visual("lod_entries", 8)
		T(#entity.visual:GetRenderEntries())["=="](1)
		T(#entity.visual:GetLODRenderEntries())["=="](2)
		local entries = entity.visual:GetLODRenderEntries()
		T(entries[1].lod_level)["=="](0)
		T(entries[2].lod_level)["=="](1)
		T(entries[1].lod_far)["=="](10)
		T(entries[2].lod_near)["=="](10)
		entity:Remove()
		Visual.Library.InvalidateSceneAcceleration()
	end)
end

T.Test3D("Graphics render3d a deduped mesh stays valid across polygon release and reuse", function()
	local Index16Array = ffi.typeof("uint16_t[?]")

	local function build_terrain_polygon()
		local samples = 5
		local cells = samples - 1
		local vertex_count = samples * samples + samples * 4
		local index_count = cells * cells * 6 + cells * 4 * 6
		local vertices = Polygon3D.VertexType(vertex_count)
		local indices = Index16Array(index_count)

		for i = 0, vertex_count - 1 do
			vertices[i].position[0] = i
			vertices[i].position[1] = (i % 7) * 0.25
			vertices[i].position[2] = i * 2
		end

		local index = 0

		for z = 0, cells - 1 do
			for x = 0, cells - 1 do
				local p00 = z * samples + x
				indices[index] = p00
				indices[index + 1] = p00 + 1
				indices[index + 2] = p00 + samples
				indices[index + 3] = p00
				indices[index + 4] = p00 + 1 + samples
				indices[index + 5] = p00 + 1
				index = index + 6
			end
		end

		local polygon = Polygon3D.New()
		polygon:UploadVertexArray(vertices, vertex_count, indices, index_count)
		return polygon
	end

	configure_camera()
	local polygon_a = build_terrain_polygon()
	local material = Material.New()
	local owner = Entity.New({Name = "mesh_dedup_owner"})
	owner:AddComponent("transform")
	owner.transform:SetPosition(Vec3(0, 0, -6))
	attach_visual(owner, polygon_a, material)
	local mesh0 = polygon_a.mesh
	T(mesh0 ~= nil and mesh0.Type == "render_mesh")["=="](true)
	local polygon_b = build_terrain_polygon()
	T(polygon_b.mesh == mesh0)["=="](true)
	polygon_a:UnreferenceVertices()
	collectgarbage("collect")
	collectgarbage("collect")
	T(polygon_b.mesh == mesh0)["=="](true)
	T(mesh0.Type == "render_mesh")["=="](true)
	T(mesh0:IsValid())["=="](true)
	T(mesh0.vertex_buffer ~= nil)["=="](true)
	owner:Remove()
	Visual.Library.InvalidateSceneAcceleration()
end)

local render = import("goluwa/render/render.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Material = import("goluwa/render3d/material.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Rect = import("goluwa/structs/rect.lua")
local Quat = import("goluwa/structs/quat.lua")
local Color = import("goluwa/structs/color.lua")
local Entity = import("goluwa/entities/entity.lua")
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
	shapes.BuildSphere(poly, 1, 16, 16)
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
	cam:SetRotation(Quat(0, 0, 0, 1))

	T.Test3D("frustum culling front/back", function(draw)
		local ent, mdl = spawn_sphere(Vec3(0, 0, -10))
		draw()
		T(mdl:IsCulled())["=="](false)
		ent.transform:SetPosition(Vec3(0, 0, 10))
		draw()
		T(mdl:IsCulled())["=="](true)
		ent:Remove()
	end)

	T.Test3D("frustum culling sides", function(draw)
		local ent, mdl = spawn_sphere(Vec3(20, 0, -10))
		draw()
		T(mdl:IsCulled())["=="](true)
		ent.transform:SetPosition(Vec3(0, 0, -10))
		draw()
		T(mdl:IsCulled())["=="](false)
		ent:Remove()
	end)

	T.Test3D("occlusion culling", function(draw)
		import("goluwa/entities/components/visual.lua").Library.SetOcclusionCulling(true)
		local occluder_ent, occluder_mdl = spawn_sphere(Vec3(0, 0, -5))
		occluder_ent.transform:SetScale(Vec3(5, 5, 1))
		local occludee_ent, occludee_mdl = spawn_sphere(Vec3(0, 0, -10), true)
		draw()
		T(occludee_mdl.using_conditional_rendering)["=="](true)
		draw()
		local stats = import("goluwa/entities/components/visual.lua").Library.GetOcclusionStats()
		T(occludee_mdl.using_conditional_rendering)["=="](true)
		occluder_ent:Remove()
		occludee_ent:Remove()
	end)
end)
