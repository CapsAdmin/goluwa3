local T = import("test/environment.lua")
local ffi = require("ffi")
local bit = require("bit")
local vk = import("goluwa/bindings/vk.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Material = import("goluwa/render3d/material.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local Texture = import("goluwa/render/texture.lua")
local Visual = import("goluwa/entities/components/visual.lua")
local gpu_culling = import("goluwa/render3d/gpu_culling.lua")
local AABB = import("goluwa/structs/aabb.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Color = import("goluwa/structs/color.lua")
local Entity = import("goluwa/entities/entity.lua")

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

local function clear_visual_instances()
	for _, visual in ipairs(Visual.Instances or {}) do
		if visual and visual.IsValid and visual:IsValid() then
			visual.Owner:Remove()
		end
	end
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

local function read_entry_indices(result, prefer_visible_entry_indices)
	if not result then return {} end

	local legacy = prefer_visible_entry_indices == false and
		result.fallback_visible_entry_indices or
		result.visible_entry_indices

	if legacy then return legacy end

	local entry_index_ptr, entry_count = gpu_culling.GetVisibleEntrySpan(result, prefer_visible_entry_indices)
	local out = {}

	if not entry_index_ptr then return out end

	for i = 0, entry_count - 1 do
		out[i + 1] = tonumber(entry_index_ptr[i])
	end

	return out
end

local function create_shadow_query_output(label_suffix)
	return gpu_culling.CreateShadowQueryOutput("test_shadow_query_" .. tostring(label_suffix or "output"))
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

T.Test3D("Graphics render3d gpu culling scaffold tracks scene acceleration invalidation and publish", function()
	configure_camera()
	T(gpu_culling.IsEnabled())["=="](true)
	local polygon3d = build_cube_polygon()
	local material = Material.New()
	local entity = Entity.New({Name = "gpu_culling_publish"})
	entity:AddComponent("transform")
	entity.transform:SetPosition(Vec3(0, 0, -6))
	attach_visual(entity, polygon3d, material)
	local previous_generation = gpu_culling.GetSceneAccelerationGeneration()
	Visual.Library.InvalidateSceneAcceleration()
	T(gpu_culling.IsSceneAccelerationDirty())["=="](true)
	T(gpu_culling.GetSceneAccelerationGeneration() > previous_generation)["=="](true)
	Visual.Library.GetVisibleVisuals()
	T(gpu_culling.IsSceneAccelerationDirty())["=="](false)
	T(gpu_culling.GetSceneAcceleration() ~= nil)["=="](true)
	T(gpu_culling.GetSceneDataset() ~= nil)["=="](true)
	T(gpu_culling.GetPublishedSceneAccelerationGeneration())["=="](gpu_culling.GetSceneAccelerationGeneration())
	entity:Remove()
end)

T.Test3D("Graphics render3d gpu culling shadow AABB pass writes visible entry indices", function()
	configure_camera()
	local polygon3d = build_cube_polygon()
	local material = Material.New()
	local inside = Entity.New({Name = "gpu_culling_shadow_inside"})
	inside:AddComponent("transform")
	inside.transform:SetPosition(Vec3(0, 0, -6))
	attach_visual(inside, polygon3d, material)
	local outside = Entity.New({Name = "gpu_culling_shadow_outside"})
	outside:AddComponent("transform")
	outside.transform:SetPosition(Vec3(50, 0, -6))
	attach_visual(outside, polygon3d, material)
	Visual.Library.InvalidateSceneAcceleration()
	Visual.Library.GetVisibleVisuals()
	local shadow_output = create_shadow_query_output("writes_visible_entry_indices")
	local result = gpu_culling.RunShadowViewAABBCulling(AABB(-10, -10, -20, 10, 10, 0), shadow_output)
	local dataset = gpu_culling.GetSceneDataset()
	local visible = {}
	local visible_entry_indices = read_entry_indices(result, true)

	for _, entry_index in ipairs(visible_entry_indices) do
		local entry = dataset.shadow_entries[entry_index + 1]

		if entry and entry.component then visible[entry.component] = true end
	end

	T(result ~= nil)["=="](true)
	T(result.visible_entry_count)["=="](1)
	T(result.fallback_visible_entry_count)["=="](0)
	T(visible[inside.visual])["=="](true)
	T(visible[outside.visual])["=="](nil)
	gpu_culling.RemoveShadowQueryOutput(shadow_output)
	inside:Remove()
	outside:Remove()
	Visual.Library.InvalidateSceneAcceleration()
end)

T.Test3D("Graphics render3d gpu culling shadow AABB pass splits instanced and fallback entries", function()
	configure_camera()
	local polygon3d = build_cube_polygon()
	local material = Material.New()
	local static_entity = Entity.New({Name = "gpu_culling_shadow_instanced_static"})
	static_entity:AddComponent("transform")
	static_entity.transform:SetPosition(Vec3(-1, 0, -6))
	attach_visual(static_entity, polygon3d, material)
	local dynamic_entity = Entity.New({Name = "gpu_culling_shadow_instanced_dynamic"})
	dynamic_entity:AddComponent("transform")
	dynamic_entity.transform:SetPosition(Vec3(1, 0, -6))
	dynamic_entity.rigid_body = {}
	attach_visual(dynamic_entity, polygon3d, material)
	Visual.Library.InvalidateSceneAcceleration()
	Visual.Library.GetVisibleVisuals()
	local shadow_output = create_shadow_query_output("splits_instanced_and_fallback")
	local result = gpu_culling.RunShadowViewAABBCulling(AABB(-10, -10, -20, 10, 10, 0), shadow_output)
	local dataset = gpu_culling.GetSceneDataset()
	local fallback_visible = {}
	local fallback_visible_entry_indices = read_entry_indices(result, false)

	for _, entry_index in ipairs(fallback_visible_entry_indices) do
		local entry = dataset.shadow_entries[entry_index + 1]

		if entry and entry.component then
			fallback_visible[entry.component] = true
		end
	end

	T(result ~= nil)["=="](true)
	T(result.visible_entry_count)["=="](2)
	T(result.fallback_visible_entry_count)["=="](0)
	T(fallback_visible[static_entity.visual])["=="](nil)
	T(fallback_visible[dynamic_entity.visual])["=="](nil)
	gpu_culling.RemoveShadowQueryOutput(shadow_output)
	static_entity:Remove()
	dynamic_entity:Remove()
	Visual.Library.InvalidateSceneAcceleration()
end)

T.Test3D("Graphics render3d gpu culling shadow AABB keeps vertex animated entries instanced", function()
	configure_camera()
	local polygon3d = build_cube_polygon()
	local material = Material.New()
	material:SetWindAmplitude(0.08)
	local static_entity = Entity.New({Name = "gpu_culling_shadow_vertex_animated_static"})
	static_entity:AddComponent("transform")
	static_entity.transform:SetPosition(Vec3(-1, 0, -6))
	attach_visual(static_entity, polygon3d, material)
	local dynamic_entity = Entity.New({Name = "gpu_culling_shadow_vertex_animated_dynamic"})
	dynamic_entity:AddComponent("transform")
	dynamic_entity.transform:SetPosition(Vec3(1, 0, -6))
	dynamic_entity.rigid_body = {}
	attach_visual(dynamic_entity, polygon3d, material)
	Visual.Library.InvalidateSceneAcceleration()
	Visual.Library.GetVisibleVisuals()
	local shadow_output = create_shadow_query_output("keeps_vertex_animated_entries_instanced")
	local result = gpu_culling.RunShadowViewAABBCulling(AABB(-10, -10, -20, 10, 10, 0), shadow_output)
	local dataset = gpu_culling.GetSceneDataset()
	local fallback_visible = {}
	local fallback_visible_entry_indices = read_entry_indices(result, false)

	for _, entry_index in ipairs(fallback_visible_entry_indices) do
		local entry = dataset.shadow_entries[entry_index + 1]

		if entry and entry.component then
			fallback_visible[entry.component] = true
		end
	end

	T(result ~= nil)["=="](true)
	T(result.visible_entry_count)["=="](2)
	T(result.fallback_visible_entry_count)["=="](0)
	T(fallback_visible[static_entity.visual])["=="](nil)
	T(fallback_visible[dynamic_entity.visual])["=="](nil)
	gpu_culling.RemoveShadowQueryOutput(shadow_output)
	static_entity:Remove()
	dynamic_entity:Remove()
	Visual.Library.InvalidateSceneAcceleration()
end)

T.Test3D("Graphics render3d gpu culling shadow AABB results stay isolated per query", function()
	configure_camera()
	local polygon3d = build_cube_polygon()
	local material = Material.New()
	local left = Entity.New({Name = "gpu_culling_shadow_left"})
	left:AddComponent("transform")
	left.transform:SetPosition(Vec3(-8, 0, -6))
	attach_visual(left, polygon3d, material)
	local right = Entity.New({Name = "gpu_culling_shadow_right"})
	right:AddComponent("transform")
	right.transform:SetPosition(Vec3(8, 0, -6))
	attach_visual(right, polygon3d, material)
	Visual.Library.InvalidateSceneAcceleration()
	Visual.Library.GetVisibleVisuals()
	local left_output = create_shadow_query_output("left_query")
	local right_output = create_shadow_query_output("right_query")
	local left_result = gpu_culling.RunShadowViewAABBCulling(AABB(-12, -4, -20, -4, 4, 0), left_output)
	local right_result = gpu_culling.RunShadowViewAABBCulling(AABB(4, -4, -20, 12, 4, 0), right_output)
	local dataset = gpu_culling.GetSceneDataset()
	local left_visible = {}
	local right_visible = {}

	for _, entry_index in ipairs(read_entry_indices(left_result, true)) do
		local entry = dataset.shadow_entries[entry_index + 1]

		if entry and entry.component then left_visible[entry.component] = true end
	end

	for _, entry_index in ipairs(read_entry_indices(right_result, true)) do
		local entry = dataset.shadow_entries[entry_index + 1]

		if entry and entry.component then right_visible[entry.component] = true end
	end

	T(left_result ~= nil)["=="](true)
	T(right_result ~= nil)["=="](true)
	T(left_result.visible_entry_count)["=="](1)
	T(right_result.visible_entry_count)["=="](1)
	T(left_visible[left.visual])["=="](true)
	T(left_visible[right.visual])["=="](nil)
	T(right_visible[left.visual])["=="](nil)
	T(right_visible[right.visual])["=="](true)
	gpu_culling.RemoveShadowQueryOutput(left_output)
	gpu_culling.RemoveShadowQueryOutput(right_output)
	left:Remove()
	right:Remove()
	Visual.Library.InvalidateSceneAcceleration()
end)

T.Test3D("Graphics render3d gpu culling scene dataset serializes static and dynamic visuals", function()
	configure_camera()
	local polygon3d = build_cube_polygon()
	local material = Material.New()
	local static_entity = Entity.New({Name = "gpu_culling_static"})
	static_entity:AddComponent("transform")
	static_entity.transform:SetPosition(Vec3(0, 0, -6))
	attach_visual(static_entity, polygon3d, material)
	local dynamic_entity = Entity.New({Name = "gpu_culling_dynamic"})
	dynamic_entity:AddComponent("transform")
	dynamic_entity.transform:SetPosition(Vec3(1, 0, -6))
	dynamic_entity.rigid_body = {}
	attach_visual(dynamic_entity, polygon3d, material)
	Visual.Library.InvalidateSceneAcceleration()
	Visual.Library.GetVisibleVisuals()
	local dataset = gpu_culling.GetSceneDataset()
	T(dataset ~= nil)["=="](true)
	T(dataset.total_visual_count)["=="](2)
	T(dataset.static_visual_count)["=="](1)
	T(dataset.dynamic_visual_count)["=="](1)
	T(dataset.static_entry_count)["=="](1)
	T(dataset.dynamic_entry_count)["=="](1)
	T(dataset.static_visuals[1].dynamic)["=="](false)
	T(dataset.dynamic_visuals[1].dynamic)["=="](true)
	T(dataset.static_visuals[1].render_entry_count)["=="](1)
	T(dataset.dynamic_visuals[1].render_entry_count)["=="](1)
	T(dataset.static_visuals[1].entries[1].polygon_guid ~= nil)["=="](true)
	T(dataset.static_visuals[1].entries[1].material_guid ~= nil)["=="](true)
	static_entity:Remove()
	dynamic_entity:Remove()
end)

T.Test3D("Graphics render3d gpu culling scene dataset serializes BVH nodes", function()
	configure_camera()
	local polygon3d = build_cube_polygon()
	local material = Material.New()
	local left = Entity.New({Name = "gpu_culling_bvh_left"})
	left:AddComponent("transform")
	left.transform:SetPosition(Vec3(-2, 0, -6))
	attach_visual(left, polygon3d, material)
	local right = Entity.New({Name = "gpu_culling_bvh_right"})
	right:AddComponent("transform")
	right.transform:SetPosition(Vec3(2, 0, -6))
	attach_visual(right, polygon3d, material)
	Visual.Library.InvalidateSceneAcceleration()
	Visual.Library.GetVisibleVisuals()
	local dataset = gpu_culling.GetSceneDataset()
	T(dataset ~= nil)["=="](true)
	T(dataset.static_bvh ~= nil)["=="](true)
	T(dataset.static_bvh.root_index)["=="](1)
	T(dataset.static_bvh.node_count >= 1)["=="](true)
	T(dataset.static_bvh.nodes[1].aabb ~= nil)["=="](true)
	T(dataset.static_bvh.nodes[1].max_cull_distance > 0)["=="](true)
	T(dataset.static_bvh.nodes[1].first ~= nil)["=="](true)
	T(dataset.static_bvh.nodes[1].last ~= nil)["=="](true)
	left:Remove()
	right:Remove()
end)

T.Test3D("Graphics render3d gpu culling allocates per-frame buffers from dataset capacity", function()
	configure_camera()
	local polygon3d = build_cube_polygon()
	local material = Material.New()
	local entity = Entity.New({Name = "gpu_culling_buffers"})
	entity:AddComponent("transform")
	entity.transform:SetPosition(Vec3(0, 0, -6))
	attach_visual(entity, polygon3d, material)
	Visual.Library.InvalidateSceneAcceleration()
	Visual.Library.GetVisibleVisuals()
	local dataset = gpu_culling.GetSceneDataset()
	local frame_buffers = gpu_culling.GetFrameBuffers()
	T(dataset ~= nil)["=="](true)
	T(frame_buffers ~= nil)["=="](true)
	T(#frame_buffers >= 1)["=="](true)
	T(gpu_culling.GetFrameBuffersGeneration())["=="](dataset.generation)
	T(frame_buffers[1].visible_entry_capacity)["=="](1)
	T(frame_buffers[1].visible_index_buffer.size)["=="](ffi.sizeof("uint32_t"))
	T(frame_buffers[1].indirect_command_buffer.size)["=="](ffi.sizeof(vk.VkDrawIndexedIndirectCommand))
	T(frame_buffers[1].indirect_count_buffer.size)["=="](ffi.sizeof("uint32_t"))
	entity:Remove()
	Visual.Library.InvalidateSceneAcceleration()
	T(gpu_culling.GetFrameBuffers())["=="](nil)
end)

T.Test3D("Graphics render3d gpu culling uploads typed binary scene records", function()
	configure_camera()
	local polygon3d = build_cube_polygon()
	local material = Material.New()
	local entity = Entity.New({Name = "gpu_culling_upload"})
	entity:AddComponent("transform")
	entity.transform:SetPosition(Vec3(0, 0, -6))
	attach_visual(entity, polygon3d, material)
	Visual.Library.InvalidateSceneAcceleration()
	Visual.Library.GetVisibleVisuals()
	local dataset = gpu_culling.GetSceneDataset()
	local dataset_buffers = gpu_culling.GetDatasetBuffers()
	local upload_types = gpu_culling.GetUploadTypes()
	T(dataset ~= nil)["=="](true)
	T(dataset_buffers ~= nil)["=="](true)
	T(gpu_culling.GetDatasetBuffersGeneration())["=="](dataset.generation)
	T(dataset_buffers.layout.main_visual_count)["=="](1)
	T(dataset_buffers.layout.main_entry_count)["=="](1)
	local visual_ptr = ffi.cast(
		ffi.typeof("$*", upload_types.visual_record),
		dataset_buffers.main_visual_buffer:Map()
	)
	local entry_ptr = ffi.cast(ffi.typeof("$*", upload_types.entry_record), dataset_buffers.main_entry_buffer:Map())
	local node_ptr = ffi.cast(
		ffi.typeof("$*", upload_types.node_record),
		dataset_buffers.static_bvh_node_buffer:Map()
	)
	T(visual_ptr[0].entry_count)["=="](1)
	T(visual_ptr[0].entry_offset)["=="](0)
	T(visual_ptr[0].cull_distance > 0)["=="](true)
	T(bit.band(visual_ptr[0].flags, upload_types.flags.visual_visible) ~= 0)["=="](true)
	T(bit.band(visual_ptr[0].flags, upload_types.flags.visual_dynamic) == 0)["=="](true)
	T(entry_ptr[0].visual_index)["=="](0)
	T(entry_ptr[0].entry_index)["=="](0)
	T(entry_ptr[0].local_min_x < entry_ptr[0].local_max_x)["=="](true)
	T(dataset_buffers.layout.static_bvh_root_index)["=="](0)
	T(node_ptr[0].first)["=="](0)
	T(node_ptr[0].last)["=="](0)
	T(bit.band(node_ptr[0].flags, upload_types.flags.node_leaf) ~= 0)["=="](true)
	entity:Remove()
	Visual.Library.InvalidateSceneAcceleration()
	T(gpu_culling.GetDatasetBuffers())["=="](nil)
end)

T.Test3D("Graphics render3d gpu culling compute pass writes visible main-view indices", function()
	local camera = configure_camera()
	local polygon3d = build_cube_polygon()
	local material = Material.New()
	local front = Entity.New({Name = "gpu_culling_compute_front"})
	front:AddComponent("transform")
	front.transform:SetPosition(Vec3(0, 0, -6))
	attach_visual(front, polygon3d, material)
	local behind = Entity.New({Name = "gpu_culling_compute_behind"})
	behind:AddComponent("transform")
	behind.transform:SetPosition(Vec3(0, 0, 6))
	attach_visual(behind, polygon3d, material)
	Visual.Library.InvalidateSceneAcceleration()
	Visual.Library.GetVisibleVisuals()
	local view_projection = camera:BuildViewMatrix() * camera:BuildProjectionMatrix()
	local result = gpu_culling.RunMainViewFrustumCulling(view_projection, camera:GetPosition())
	local visible_entry_indices = read_entry_indices(result, true)
	T(result ~= nil)["=="](true)
	T(result.visible_entry_count)["=="](1)
	T(#visible_entry_indices)["=="](1)
	T(visible_entry_indices[1])["=="](0)
	front:Remove()
	behind:Remove()
	Visual.Library.InvalidateSceneAcceleration()
end)

T.Test3D("Graphics render3d gpu culling compute pass expands visible visuals into entry indices", function()
	local camera = configure_camera()
	local polygon3d = build_cube_polygon()
	local material = Material.New()
	local visible = Entity.New({Name = "gpu_culling_compute_multi_visible"})
	visible:AddComponent("transform")
	visible.transform:SetPosition(Vec3(0, 0, -6))
	attach_visual(visible, polygon3d, material)
	add_visual_primitive(visible, polygon3d, material, "gpu_culling_compute_multi_visible_second")
	visible.visual:BuildAABB()
	local hidden = Entity.New({Name = "gpu_culling_compute_multi_hidden"})
	hidden:AddComponent("transform")
	hidden.transform:SetPosition(Vec3(0, 0, 6))
	attach_visual(hidden, polygon3d, material)
	Visual.Library.InvalidateSceneAcceleration()
	Visual.Library.GetVisibleVisuals()
	local view_projection = camera:BuildViewMatrix() * camera:BuildProjectionMatrix()
	local result = gpu_culling.RunMainViewFrustumCulling(view_projection, camera:GetPosition())
	local visible_entry_indices = read_entry_indices(result, true)
	T(result ~= nil)["=="](true)
	T(result.visible_entry_count)["=="](2)
	T(#visible_entry_indices)["=="](2)
	T(visible_entry_indices[1])["=="](0)
	T(visible_entry_indices[2])["=="](1)
	visible:Remove()
	hidden:Remove()
	Visual.Library.InvalidateSceneAcceleration()
end)

T.Test3D("Graphics render3d gpu culling visible render entries expand GPU-visible entries", function()
	configure_camera()
	local polygon3d = build_cube_polygon()
	local material = Material.New()
	local visible = Entity.New({Name = "gpu_culling_visible_entries_visible"})
	visible:AddComponent("transform")
	visible.transform:SetPosition(Vec3(0, 0, -6))
	attach_visual(visible, polygon3d, material)
	add_visual_primitive(visible, polygon3d, material, "gpu_culling_visible_entries_visible_second")
	visible.visual:BuildAABB()
	local hidden = Entity.New({Name = "gpu_culling_visible_entries_hidden"})
	hidden:AddComponent("transform")
	hidden.transform:SetPosition(Vec3(0, 0, 6))
	attach_visual(hidden, polygon3d, material)
	Visual.Library.InvalidateSceneAcceleration()
	local visible_entries = Visual.Library.GetVisibleRenderEntries()
	T(#visible_entries)["=="](2)
	T(visible_entries[1].component)["=="](visible.visual)
	T(visible_entries[2].component)["=="](visible.visual)
	visible:Remove()
	hidden:Remove()
	Visual.Library.InvalidateSceneAcceleration()
end)

T.Test3D("Graphics render3d gpu culling builds indirect commands from visible entry indices", function()
	local camera = configure_camera()
	local polygon3d = build_cube_polygon()
	local material = Material.New()
	local visible = Entity.New({Name = "gpu_culling_indirect_visible"})
	visible:AddComponent("transform")
	visible.transform:SetPosition(Vec3(0, 0, -6))
	attach_visual(visible, polygon3d, material)
	add_visual_primitive(visible, polygon3d, material, "gpu_culling_indirect_visible_second")
	visible.visual:BuildAABB()
	local hidden = Entity.New({Name = "gpu_culling_indirect_hidden"})
	hidden:AddComponent("transform")
	hidden.transform:SetPosition(Vec3(0, 0, 6))
	attach_visual(hidden, polygon3d, material)
	Visual.Library.InvalidateSceneAcceleration()
	Visual.Library.GetVisibleVisuals()
	local view_projection = camera:BuildViewMatrix() * camera:BuildProjectionMatrix()
	local cull_result = gpu_culling.RunMainViewFrustumCulling(view_projection, camera:GetPosition())
	local frame_buffers = gpu_culling.GetFrameBuffers()
	local command_ptr = ffi.cast(
		ffi.typeof("$*", vk.VkDrawIndexedIndirectCommand),
		frame_buffers[cull_result.frame_index].indirect_command_buffer:Map()
	)
	T(cull_result ~= nil)["=="](true)
	T(cull_result.indirect_command_count)["=="](2)
	T(command_ptr[0].indexCount)["=="](polygon3d:GetMesh().index_buffer:GetIndexCount())
	T(command_ptr[0].instanceCount)["=="](1)
	T(command_ptr[0].firstInstance)["=="](0)
	T(command_ptr[1].firstInstance)["=="](1)
	visible:Remove()
	hidden:Remove()
	Visual.Library.InvalidateSceneAcceleration()
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

T.Test3D("Graphics render3d shadow visible render entries expand shadow-visible components", function()
	configure_camera()
	local polygon3d = build_cube_polygon()
	local material = Material.New()
	local inside = Entity.New({Name = "shadow_render_entries_inside"})
	inside:AddComponent("transform")
	inside.transform:SetPosition(Vec3(0, 0, -6))
	attach_visual(inside, polygon3d, material)
	add_visual_primitive(inside, polygon3d, material, "shadow_render_entries_inside_second")
	inside.visual:BuildAABB()
	local outside = Entity.New({Name = "shadow_render_entries_outside"})
	outside:AddComponent("transform")
	outside.transform:SetPosition(Vec3(50, 0, -6))
	attach_visual(outside, polygon3d, material)
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
		GetCascadeWorldAABB = function()
			return AABB(-10, -10, -20, 10, 10, 0)
		end,
	}
	local render_entries = Visual.Library.GetShadowVisibleRenderEntries(shadow_map, 1)
	T(#render_entries)["=="](2)
	T(render_entries[1].component)["=="](inside.visual)
	T(render_entries[2].component)["=="](inside.visual)
	inside:Remove()
	outside:Remove()
	Visual.Library.InvalidateSceneAcceleration()
end)

T.Test3D("Graphics render3d shadow visible list reuses stable cascades", function()
	configure_camera()
	local polygon3d = build_cube_polygon()
	local material = Material.New()
	local entity = Entity.New({Name = "stable_shadow_cache"})
	entity:AddComponent("transform")
	entity.transform:SetPosition(Vec3(0, 0, -6))
	attach_visual(entity, polygon3d, material)
	Visual.Library.InvalidateSceneAcceleration()
	local query_aabb = AABB(-10, -10, -20, 10, 10, 0)
	local visibility_checks = 0
	local shadow_map = {
		IsWorldAABBVisible = function(self, cascade_idx, world_aabb)
			visibility_checks = visibility_checks + 1
			return world_aabb.min_x < 10
		end,
		IsWorldAABBTooSmall = function()
			return false
		end,
		UsesTessellatedMaterial = function()
			return false
		end,
		GetCascadeWorldAABB = function()
			return query_aabb
		end,
	}
	local initially_visible = visible_lookup(Visual.Library.GetShadowVisibleVisuals(shadow_map, 1))
	local checks_after_first = visibility_checks
	local cached_visible = visible_lookup(Visual.Library.GetShadowVisibleVisuals(shadow_map, 1))
	T(initially_visible[entity.visual])["=="](true)
	T(cached_visible[entity.visual])["=="](true)
	T(visibility_checks)["=="](checks_after_first)
	entity.transform:SetPosition(Vec3(50, 0, -6))
	local moved_visible = visible_lookup(Visual.Library.GetShadowVisibleVisuals(shadow_map, 1))
	T(moved_visible[entity.visual])["=="](nil)
	T(visibility_checks >= checks_after_first)["=="](true)
	entity:Remove()
end)

T.Test3D("Graphics render3d shadows honor main-view occlusion", function(draw)
	configure_camera()
	Visual.Library.SetOcclusionCulling(true)
	local polygon3d = build_cube_polygon()
	local material = Material.New()
	local occluder = Entity.New({Name = "shadow_occluder"})
	occluder:AddComponent("transform")
	occluder.transform:SetPosition(Vec3(0, 0, -5))
	attach_visual(occluder, polygon3d, material)
	occluder.transform:SetScale(Vec3(6, 6, 2))
	local occluded = Entity.New({Name = "shadow_occluded"})
	occluded:AddComponent("transform")
	occluded.transform:SetPosition(Vec3(0, 0, -10))
	attach_visual(occluded, polygon3d, material)
	occluded.visual:SetUseOcclusionCulling(true)
	Visual.Library.InvalidateSceneAcceleration()
	local shadow_map = {
		IsWorldAABBVisible = function()
			return true
		end,
		IsWorldAABBTooSmall = function()
			return false
		end,
		UsesTessellatedMaterial = function()
			return false
		end,
		GetCascadeWorldAABB = function()
			return AABB(-20, -20, -20, 20, 20, 0)
		end,
	}
	draw()
	draw()
	local visible = visible_lookup(Visual.Library.GetShadowVisibleVisuals(shadow_map, 1))
	local render_entries = Visual.Library.GetShadowVisibleRenderEntries(shadow_map, 1)
	local found_occluded_entry = false

	for _, payload in ipairs(render_entries) do
		if payload.component == occluded.visual then
			found_occluded_entry = true

			break
		end
	end

	occluder:Remove()
	occluded:Remove()
	Visual.Library.SetOcclusionCulling(false)
	T(visible[occluder.visual])["=="](true)
	T(visible[occluded.visual])["=="](nil)
	T(found_occluded_entry)["=="](false)
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
		T(mdl:IsCulled())["=="](false)
		ent.transform:SetPosition(Vec3(0, 0, 10)) -- Behind
		draw()
		T(mdl:IsCulled())["=="](true)
		ent:Remove()
	end)

	T.Test3D("frustum culling sides", function(draw)
		local ent, mdl = spawn_sphere(Vec3(20, 0, -10)) -- Far right
		draw()
		T(mdl:IsCulled())["=="](true)
		ent.transform:SetPosition(Vec3(0, 0, -10)) -- Center
		draw()
		T(mdl:IsCulled())["=="](false)
		ent:Remove()
	end)

	T.Test3D("occlusion culling", function(draw)
		import("goluwa/entities/components/visual.lua").Library.SetOcclusionCulling(true)
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
		local stats = import("goluwa/entities/components/visual.lua").Library.GetOcclusionStats()
		--print("Occlusion stats:", stats.total, stats.with_occlusion, stats.submitted_with_conditional)
		-- We can't easily check if the GPU actually culled it, 
		-- but we can check if it was submitted with conditional rendering.
		T(occludee_mdl.using_conditional_rendering)["=="](true)
		occluder_ent:Remove()
		occludee_ent:Remove()
	end)
end)
