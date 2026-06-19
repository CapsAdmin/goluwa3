local event = import("goluwa/event.lua")
local commands = import("goluwa/commands.lua")
local prototype = import("goluwa/prototype.lua")
-- Pre-register to break import cycle: visual -> render3d -> light -> visual
local Visual = prototype.CreateTemplate("visual")
import.loaded["goluwa/ecs/components/3d/visual.lua"] = Visual
local BVH = import("goluwa/physics/bvh.lua")
local AABB = import("goluwa/structs/aabb.lua")
local Material = import("goluwa/render3d/material.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local render = import("goluwa/render/render.lua")
local Texture = import("goluwa/render/texture.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local gpu_culling = import("goluwa/render3d/gpu_culling.lua")
local test_helper = import("goluwa/test.lua")
local model_loader = import("goluwa/render3d/model_loader.lua")
local Entity = import("goluwa/ecs/entity.lua")
local system = import("goluwa/system.lua")
local ffi = require("ffi")
local visual = {}

local function registry_insert(registry, index_field, component)
	if component[index_field] then return end

	registry[#registry + 1] = component
	component[index_field] = #registry
end

local function registry_remove(registry, index_field, component)
	local index = component[index_field]

	if not index then return end

	local last_index = #registry
	local last_component = registry[last_index]
	registry[index] = last_component
	registry[last_index] = nil
	component[index_field] = nil

	if last_component and last_component ~= component then
		last_component[index_field] = index
	end
end

local function refresh_shadow_registry(component)
	if component.CastShadows then
		registry_insert(visual.shadow_casters, "shadow_registry_index", component)
	else
		registry_remove(visual.shadow_casters, "shadow_registry_index", component)
	end
end

local function refresh_forward_overlay_registry(component)
	if component.HasIgnoreZRenderEntries then
		registry_insert(visual.forward_overlay_components, "forward_overlay_registry_index", component)
	else
		registry_remove(visual.forward_overlay_components, "forward_overlay_registry_index", component)
	end
end

local function refresh_occlusion_registries(component)
	component.using_conditional_rendering = component.UseOcclusionCulling and
		visual.IsOcclusionCullingEnabled and
		visual.IsOcclusionCullingEnabled() or
		false
end

local function refresh_visual_registries(component)
	refresh_shadow_registry(component)
	refresh_occlusion_registries(component)
end

local function get_shadow_debug_target_name(component)
	local owner = component and component.Owner
	return owner and owner.Name or tostring(component)
end

local function shadow_debug_matches(component)
	local filter = visual.shadow_debug_filter

	if filter == nil or filter == false then return false end

	local name = get_shadow_debug_target_name(component)

	if filter == true then return true end

	return name == filter or name:find(filter, 1, true) ~= nil
end

local function get_shadow_debug_frame_hits()
	local frame = system.GetFrameNumber and system.GetFrameNumber() or 0

	if visual.shadow_debug_frame ~= frame then
		visual.shadow_debug_frame = frame
		visual.shadow_debug_hits = {}
	end

	return visual.shadow_debug_hits
end

local function record_shadow_debug_hit(component, cascade_idx, state, entries)
	if not shadow_debug_matches(component) then return end

	local name = get_shadow_debug_target_name(component)
	local hits = get_shadow_debug_frame_hits()
	local hit = hits[name]

	if not hit then
		hit = {name = name, states = {}}
		hits[name] = hit
	end

	local state_key = tostring(cascade_idx) .. ":" .. state
	hit.states[state_key] = (hit.states[state_key] or 0) + (entries or 0)

	if visual.shadow_debug_log then
		logn(
			"[shadow-debug] ",
			name,
			" cascade=",
			cascade_idx,
			" state=",
			state,
			" entries=",
			entries or 0
		)
	end
end

local function get_shadow_draw_call_stats_store()
	visual.shadow_draw_call_stats = visual.shadow_draw_call_stats or setmetatable({}, {__mode = "k"})
	return visual.shadow_draw_call_stats
end

local function get_shadow_gpu_culling_stats_store()
	visual.shadow_gpu_culling_stats = visual.shadow_gpu_culling_stats or setmetatable({}, {__mode = "k"})
	return visual.shadow_gpu_culling_stats
end

local function get_main_gpu_culling_stats_store()
	visual.main_gpu_culling_stats = visual.main_gpu_culling_stats or {}
	return visual.main_gpu_culling_stats
end

local function get_shadow_visible_list_cache_store()
	visual.shadow_visible_list_cache = visual.shadow_visible_list_cache or setmetatable({}, {__mode = "k"})
	return visual.shadow_visible_list_cache
end

local get_cull_camera_position

local function get_shadow_visible_list_cache(shadow_map, cascade_idx)
	local stats = get_shadow_visible_list_cache_store()
	local map_stats = stats[shadow_map]

	if not map_stats then
		map_stats = {cascades = {}}
		stats[shadow_map] = map_stats
	end

	local cascade_cache = map_stats.cascades[cascade_idx]

	if not cascade_cache then
		cascade_cache = {list = {}}
		map_stats.cascades[cascade_idx] = cascade_cache
	end

	return cascade_cache
end

local function shadow_cache_matches_aabb(cache, query_aabb)
	if cache.has_query_aabb ~= (query_aabb ~= nil) then return false end

	if not query_aabb then return true end

	return cache.query_min_x == query_aabb.min_x and
		cache.query_min_y == query_aabb.min_y and
		cache.query_min_z == query_aabb.min_z and
		cache.query_max_x == query_aabb.max_x and
		cache.query_max_y == query_aabb.max_y and
		cache.query_max_z == query_aabb.max_z
end

local function shadow_cache_matches_camera(cache, camera_position)
	if cache.has_camera_position ~= (camera_position ~= nil) then return false end

	if not camera_position then return true end

	return cache.camera_x == camera_position.x and
		cache.camera_y == camera_position.y and
		cache.camera_z == camera_position.z
end

local function can_reuse_shadow_visible_list(
	cache,
	query_aabb,
	camera_position,
	shadow_volume_change_version,
	shadow_visible_list_version
)
	if not cache.valid then return false end

	if not query_aabb then return false end

	if cache.shadow_volume_change_version ~= shadow_volume_change_version then
		return false
	end

	if cache.shadow_visible_list_version ~= shadow_visible_list_version then
		return false
	end

	if not shadow_cache_matches_aabb(cache, query_aabb) then return false end

	if not shadow_cache_matches_camera(cache, camera_position) then return false end

	return true
end

local function can_reuse_shadow_gpu_cull_result(
	cache,
	query_aabb,
	camera_position,
	shadow_volume_change_version,
	shadow_visible_list_version
)
	if not cache.gpu_cull_result_valid then return false end

	if not query_aabb then return false end

	if cache.shadow_volume_change_version ~= shadow_volume_change_version then
		return false
	end

	if cache.shadow_visible_list_version ~= shadow_visible_list_version then
		return false
	end

	if not shadow_cache_matches_aabb(cache, query_aabb) then return false end

	if not shadow_cache_matches_camera(cache, camera_position) then return false end

	return true
end

local function update_shadow_cache_query_state(
	cache,
	query_aabb,
	camera_position,
	shadow_volume_change_version,
	shadow_visible_list_version
)
	cache.shadow_volume_change_version = shadow_volume_change_version
	cache.shadow_visible_list_version = shadow_visible_list_version
	cache.has_query_aabb = query_aabb ~= nil
	cache.has_camera_position = camera_position ~= nil

	if query_aabb then
		cache.query_min_x = query_aabb.min_x
		cache.query_min_y = query_aabb.min_y
		cache.query_min_z = query_aabb.min_z
		cache.query_max_x = query_aabb.max_x
		cache.query_max_y = query_aabb.max_y
		cache.query_max_z = query_aabb.max_z
	end

	if camera_position then
		cache.camera_x = camera_position.x
		cache.camera_y = camera_position.y
		cache.camera_z = camera_position.z
	end
end

local function get_cached_shadow_volume_change_version(cache, query_aabb)
	if not query_aabb then return nil end

	local current_shadow_change_version = visual.shadow_change_version_counter or 0

	if
		cache.shadow_volume_query_global_change_version == current_shadow_change_version and
		shadow_cache_matches_aabb(cache, query_aabb)
	then
		return cache.shadow_volume_change_version
	end

	local shadow_volume_change_version = visual.GetShadowVolumeChangeVersion(query_aabb)
	cache.shadow_volume_query_global_change_version = current_shadow_change_version
	cache.shadow_volume_change_version = shadow_volume_change_version
	return shadow_volume_change_version
end

local function get_shadow_visibility_cache_version()
	local version = visual.shadow_visible_list_version or 0

	if
		visual.IsOcclusionCullingEnabled() and
		gpu_culling.IsEnabled() and
		gpu_culling.GetOcclusionMode and
		gpu_culling.GetOcclusionMode() == "hiz"
	then
		version = version + (system.GetFrameNumber and system.GetFrameNumber() or 0)
	end

	return version
end

local function update_shadow_visible_list_cache(
	cache,
	query_aabb,
	camera_position,
	shadow_volume_change_version,
	shadow_visible_list_version
)
	cache.valid = true
	update_shadow_cache_query_state(
		cache,
		query_aabb,
		camera_position,
		shadow_volume_change_version,
		shadow_visible_list_version
	)
end

local function ensure_shadow_gpu_cull_output(cache, shadow_map, cascade_idx)
	if shadow_map.GetShadowCullOutput then
		return shadow_map:GetShadowCullOutput(cascade_idx)
	end

	local dataset_buffers = gpu_culling.GetDatasetBuffers()
	local layout = dataset_buffers and dataset_buffers.layout or nil
	local shadow_entry_capacity = math.max(layout and layout.shadow_entry_count or 0, 1)
	local shadow_instanced_batch_count = math.max(layout and layout.shadow_instanced_batch_count or 0, 1)
	local shadow_instance_capacity = math.max(layout and layout.shadow_instance_count or 0, 1)
	local output = cache.gpu_cull_output

	if
		output and
		output.shadow_entry_capacity == shadow_entry_capacity and
		output.shadow_instanced_batch_count == shadow_instanced_batch_count and
		output.shadow_instance_capacity == shadow_instance_capacity
	then
		return output
	end

	local descriptor_slot = output and output.descriptor_slot or nil

	if output then gpu_culling.RemoveShadowQueryOutput(output) end

	output = gpu_culling.CreateShadowQueryOutput(
		string.format("visual_shadow_query_%s_%s", tostring(shadow_map), tostring(cascade_idx)),
		shadow_entry_capacity,
		shadow_instanced_batch_count,
		shadow_instance_capacity,
		descriptor_slot
	)
	cache.gpu_cull_output = output
	return output
end

local function get_shadow_gpu_cull_result(shadow_map, cascade_idx, include_visible_entry_indices)
	local cache = get_shadow_visible_list_cache(shadow_map, cascade_idx)
	local camera_position = get_cull_camera_position()
	local query_aabb = shadow_map.GetCascadeWorldAABB and
		shadow_map:GetCascadeWorldAABB(cascade_idx) or
		nil
	local shadow_volume_change_version = get_cached_shadow_volume_change_version(cache, query_aabb)
	local shadow_visible_list_version = get_shadow_visibility_cache_version()
	local read_visible_entry_indices = include_visible_entry_indices ~= false

	if
		can_reuse_shadow_gpu_cull_result(
			cache,
			query_aabb,
			camera_position,
			shadow_volume_change_version,
			shadow_visible_list_version
		) and
		(
			not read_visible_entry_indices or
			cache.gpu_cull_result.visible_entry_indices_ready
		)
	then
		return gpu_culling.GetSceneDataset(),
		cache.gpu_cull_result,
		cache,
		query_aabb,
		camera_position,
		shadow_volume_change_version,
		shadow_visible_list_version
	end

	cache.gpu_cull_result = nil
	cache.gpu_cull_result_valid = false

	if gpu_culling.IsEnabled() and not visual.noculling and query_aabb then
		local dataset = gpu_culling.GetSceneDataset()
		local shadow_output = ensure_shadow_gpu_cull_output(cache, shadow_map, cascade_idx)
		local cull_result = dataset and
			gpu_culling.RunShadowViewAABBCulling(query_aabb, shadow_output, nil, read_visible_entry_indices) or
			nil

		if cull_result then
			cache.gpu_cull_result = cull_result
			cache.gpu_cull_result_valid = true
			update_shadow_cache_query_state(
				cache,
				query_aabb,
				camera_position,
				shadow_volume_change_version,
				shadow_visible_list_version
			)
			return dataset,
			cull_result,
			cache,
			query_aabb,
			camera_position,
			shadow_volume_change_version,
			shadow_visible_list_version
		end
	end

	return nil,
	nil,
	cache,
	query_aabb,
	camera_position,
	shadow_volume_change_version,
	shadow_visible_list_version
end

local function record_shadow_draw_calls(shadow_map, cascade_idx, draw_call_count)
	if not shadow_map or not cascade_idx or draw_call_count <= 0 then return end

	local stats = get_shadow_draw_call_stats_store()
	local map_stats = stats[shadow_map]

	if not map_stats then
		map_stats = {cascades = {}}
		stats[shadow_map] = map_stats
	end

	map_stats.cascades[cascade_idx] = (map_stats.cascades[cascade_idx] or 0) + draw_call_count
	map_stats.last_updated_frame = system.GetFrameNumber and system.GetFrameNumber() or 0
end

local function reset_shadow_draw_calls(shadow_map, cascade_idx)
	if not shadow_map or not cascade_idx then return end

	local stats = get_shadow_draw_call_stats_store()
	local map_stats = stats[shadow_map]

	if not map_stats then
		map_stats = {cascades = {}}
		stats[shadow_map] = map_stats
	end

	map_stats.cascades[cascade_idx] = 0
	map_stats.last_updated_frame = system.GetFrameNumber and system.GetFrameNumber() or 0
end

local function record_shadow_gpu_culling_stats(shadow_map, cascade_idx, data)
	if not shadow_map or not cascade_idx then return end

	local stats = get_shadow_gpu_culling_stats_store()
	local map_stats = stats[shadow_map]

	if not map_stats then
		map_stats = {cascades = {}}
		stats[shadow_map] = map_stats
	end

	local cascade_stats = map_stats.cascades[cascade_idx] or {}
	map_stats.cascades[cascade_idx] = cascade_stats
	map_stats.last_updated_frame = system.GetFrameNumber and system.GetFrameNumber() or 0
	cascade_stats.frame = map_stats.last_updated_frame
	cascade_stats.visible_entry_count = data.visible_entry_count or 0
	cascade_stats.fallback_visible_entry_count = data.fallback_visible_entry_count or 0
	cascade_stats.gpu_packed_entry_count = data.gpu_packed_entry_count or 0
	cascade_stats.gpu_packed_draw_calls = data.gpu_packed_draw_calls or 0
	cascade_stats.gpu_active_batch_count = data.gpu_active_batch_count or 0
	cascade_stats.gpu_total_batch_count = data.gpu_total_batch_count or 0
	cascade_stats.fallback_submitted_entry_count = data.fallback_submitted_entry_count or 0
	cascade_stats.fallback_instanced_draw_calls = data.fallback_instanced_draw_calls or 0
	cascade_stats.fallback_singleton_draw_calls = data.fallback_singleton_draw_calls or 0
	cascade_stats.fallback_missing_world_matrix_count = data.fallback_missing_world_matrix_count or 0
	return cascade_stats
end

local function record_main_gpu_culling_stats(data)
	local stats = get_main_gpu_culling_stats_store()
	stats.frame = system.GetFrameNumber and system.GetFrameNumber() or 0
	stats.visible_entry_count = data.visible_entry_count or 0
	stats.fallback_visible_entry_count = data.fallback_visible_entry_count or 0
	stats.gpu_packed_entry_count = data.gpu_packed_entry_count or 0
	stats.gpu_packed_draw_calls = data.gpu_packed_draw_calls or 0
	stats.gpu_active_batch_count = data.gpu_active_batch_count or 0
	stats.gpu_total_batch_count = data.gpu_total_batch_count or 0
	stats.fallback_submitted_entry_count = data.fallback_submitted_entry_count or 0
	return stats
end

local function create_empty_aabb()
	return AABB(math.huge, math.huge, math.huge, -math.huge, -math.huge, -math.huge)
end

local function material_ignores_z(material)
	return material and material.GetIgnoreZ and material:GetIgnoreZ() or false
end

local last_scene_voxelizer_invalidation_frame = -1

local function voxelizer_has_dirty_work(voxelizer)
	if not voxelizer or not voxelizer.GetClipmaps then return false end

	for _, clipmap in ipairs(voxelizer.GetClipmaps() or {}) do
		if clipmap.dirty then return true end
	end

	return false
end

local function invalidate_scene_voxelizer(full_rebuild)
	if not render3d or not render3d.GetSceneVoxelizer then return end

	local voxelizer = render3d.GetSceneVoxelizer()

	if not voxelizer or not voxelizer.InvalidateAll then return end

	if voxelizer.IsEnabled and not voxelizer:IsEnabled() then return end

	local frame = system.GetFrameNumber and system.GetFrameNumber() or -1

	if
		last_scene_voxelizer_invalidation_frame == frame and
		voxelizer_has_dirty_work(voxelizer)
	then
		return
	end

	last_scene_voxelizer_invalidation_frame = frame
	voxelizer.InvalidateAll(full_rebuild ~= false)
end

local function invalidate_scene_acceleration()
	visual.scene_acceleration = visual.scene_acceleration or {}
	visual.scene_acceleration.dirty = true
	visual.shadow_visible_list_version = (visual.shadow_visible_list_version or 0) + 1
	gpu_culling.InvalidateSceneAcceleration()
	invalidate_scene_voxelizer(true)
end

local function next_shadow_change_version()
	visual.shadow_change_version_counter = (visual.shadow_change_version_counter or 0) + 1
	return visual.shadow_change_version_counter
end

local function mark_shadow_change(component)
	if not component then return end

	component.shadow_change_version = next_shadow_change_version()
end

local function is_visual_dynamic(component)
	local owner = component and component.Owner

	if owner and owner.rigid_body then return true end

	local transform = owner and owner.transform
	return transform and transform.IsFrameDynamic and transform:IsFrameDynamic() or false
end

local function add_scene_acceleration_item(items, component, bounds)
	if not bounds or bounds.min_x > bounds.max_x then return end

	items[#items + 1] = {
		component = component,
		world_aabb = bounds,
		cull_distance = component.CullDistance,
		shadow_change_version = component.shadow_change_version or 0,
		min_x = bounds.min_x,
		min_y = bounds.min_y,
		min_z = bounds.min_z,
		max_x = bounds.max_x,
		max_y = bounds.max_y,
		max_z = bounds.max_z,
		centroid_x = (bounds.min_x + bounds.max_x) * 0.5,
		centroid_y = (bounds.min_y + bounds.max_y) * 0.5,
		centroid_z = (bounds.min_z + bounds.max_z) * 0.5,
	}
end

local function get_scene_acceleration_item_bounds(item)
	return item
end

local function get_scene_acceleration_item_centroid(item)
	return item.centroid_x, item.centroid_y, item.centroid_z
end

local function annotate_tree_max_cull_distance(node, items)
	if not node then return 0 end

	if node.first then
		local max_cull_distance = 0

		for i = node.first, node.last do
			local cull_distance = items[i].cull_distance or 0

			if cull_distance > max_cull_distance then max_cull_distance = cull_distance end
		end

		node.max_cull_distance = max_cull_distance
		return max_cull_distance
	end

	local left_distance = annotate_tree_max_cull_distance(node.left, items)
	local right_distance = annotate_tree_max_cull_distance(node.right, items)
	node.max_cull_distance = math.max(left_distance, right_distance)
	return node.max_cull_distance
end

local function annotate_tree_max_shadow_change_version(node, items)
	if not node then return 0 end

	if node.first then
		local max_shadow_change_version = 0

		for i = node.first, node.last do
			local shadow_change_version = items[i].shadow_change_version or 0

			if shadow_change_version > max_shadow_change_version then
				max_shadow_change_version = shadow_change_version
			end
		end

		node.max_shadow_change_version = max_shadow_change_version
		return max_shadow_change_version
	end

	local left_version = annotate_tree_max_shadow_change_version(node.left, items)
	local right_version = annotate_tree_max_shadow_change_version(node.right, items)
	node.max_shadow_change_version = math.max(left_version, right_version)
	return node.max_shadow_change_version
end

local function is_aabb_intersecting(a, b)
	if not a or not b then return true end

	return not (
		a.min_x > b.max_x or
		b.min_x > a.max_x or
		a.min_y > b.max_y or
		b.min_y > a.max_y or
		a.min_z > b.max_z or
		b.min_z > a.max_z
	)
end

local function can_use_shadow_aabb_cull(component, render_entries)
	render_entries = render_entries or component:GetRenderEntries()

	for _, entry in ipairs(render_entries) do
		local material = component:GetResolvedMaterial(entry)

		if material and material:GetHeightTexture() and material:GetHeightScale() > 0 then
			return false
		end
	end

	return true
end

local function rebuild_scene_acceleration()
	local items = {}
	local dynamic_components = {}
	local shadow_items = {}
	local dynamic_shadow_components = {}
	local non_aabb_shadow_components = {}

	for _, component in ipairs(Visual.Instances or {}) do
		local render_entries = component:GetRenderEntries()

		if render_entries[1] then
			local world_aabb = component:GetWorldAABB()
			local shadow_aabb_cull = component.CastShadows and can_use_shadow_aabb_cull(component, render_entries)

			if is_visual_dynamic(component) then
				dynamic_components[#dynamic_components + 1] = component

				if component.CastShadows then
					if shadow_aabb_cull then
						dynamic_shadow_components[#dynamic_shadow_components + 1] = component
					else
						non_aabb_shadow_components[#non_aabb_shadow_components + 1] = component
					end
				end
			else
				add_scene_acceleration_item(items, component, world_aabb)

				if component.CastShadows then
					if shadow_aabb_cull then
						add_scene_acceleration_item(shadow_items, component, world_aabb)
					else
						non_aabb_shadow_components[#non_aabb_shadow_components + 1] = component
					end
				end
			end
		end
	end

	visual.scene_acceleration = visual.scene_acceleration or {}
	visual.scene_acceleration.items = items
	visual.scene_acceleration.dynamic_components = dynamic_components
	visual.scene_acceleration.shadow_items = shadow_items
	visual.scene_acceleration.dynamic_shadow_components = dynamic_shadow_components
	visual.scene_acceleration.non_aabb_shadow_components = non_aabb_shadow_components
	visual.scene_acceleration.tree = #items > 0 and
		BVH.Build(
			items,
			get_scene_acceleration_item_bounds,
			get_scene_acceleration_item_centroid,
			8
		) or
		nil
	visual.scene_acceleration.shadow_tree = #shadow_items > 0 and
		BVH.Build(
			shadow_items,
			get_scene_acceleration_item_bounds,
			get_scene_acceleration_item_centroid,
			8
		) or
		nil
	visual.scene_acceleration.visual_count = #(Visual.Instances or {})
	visual.scene_acceleration.dirty = false
	visual.scene_acceleration.visible_frame = nil
	visual.scene_acceleration.visible_cull_result = nil
	visual.scene_acceleration.visible_gpu_cull_result = nil
	visual.scene_acceleration.visible_gpu_cull_result_frame = nil
	visual.scene_acceleration.visible_components = nil
	visual.scene_acceleration.visible_render_entries = nil
	visual.scene_acceleration.visible_render_entries_frame = nil

	if visual.scene_acceleration.tree then
		visual.scene_acceleration.tree.components = visual.scene_acceleration.tree.items
		visual.scene_acceleration.tree.items = nil
		annotate_tree_max_cull_distance(visual.scene_acceleration.tree.root, visual.scene_acceleration.tree.components)
		visual.scene_acceleration.tree.traversal_context = visual.scene_acceleration.tree.traversal_context or {
			node_stack = {},
		}
	end

	if visual.scene_acceleration.shadow_tree then
		visual.scene_acceleration.shadow_tree.components = visual.scene_acceleration.shadow_tree.items
		visual.scene_acceleration.shadow_tree.items = nil
		annotate_tree_max_cull_distance(visual.scene_acceleration.shadow_tree.root, visual.scene_acceleration.shadow_tree.components)
		annotate_tree_max_shadow_change_version(visual.scene_acceleration.shadow_tree.root, visual.scene_acceleration.shadow_tree.components)
		visual.scene_acceleration.shadow_tree.traversal_context = visual.scene_acceleration.shadow_tree.traversal_context or
			{
				node_stack = {},
			}
	end

	return gpu_culling.PublishSceneAcceleration(visual.scene_acceleration)
end

local function ensure_scene_acceleration()
	local acceleration = visual.scene_acceleration

	if
		not acceleration or
		acceleration.dirty or
		acceleration.visual_count ~= #(
			Visual.Instances or
			{}
		)
		or
		(
			gpu_culling.IsSceneAccelerationDirty() and
			gpu_culling.GetPublishedSceneAccelerationGeneration() ~= gpu_culling.GetSceneAccelerationGeneration()
		)
	then
		return rebuild_scene_acceleration()
	end

	return acceleration
end

local function expand_aabb_with_transformed(source, matrix, target)
	if not source then return end

	if matrix.m03 == 0 and matrix.m13 == 0 and matrix.m23 == 0 and matrix.m33 == 1 then
		local center_x = (source.min_x + source.max_x) * 0.5
		local center_y = (source.min_y + source.max_y) * 0.5
		local center_z = (source.min_z + source.max_z) * 0.5
		local extent_x = (source.max_x - source.min_x) * 0.5
		local extent_y = (source.max_y - source.min_y) * 0.5
		local extent_z = (source.max_z - source.min_z) * 0.5
		local world_x, world_y, world_z = matrix:TransformVectorUnpacked(center_x, center_y, center_z)
		local world_extent_x = math.abs(matrix.m00) * extent_x + math.abs(matrix.m10) * extent_y + math.abs(matrix.m20) * extent_z
		local world_extent_y = math.abs(matrix.m01) * extent_x + math.abs(matrix.m11) * extent_y + math.abs(matrix.m21) * extent_z
		local world_extent_z = math.abs(matrix.m02) * extent_x + math.abs(matrix.m12) * extent_y + math.abs(matrix.m22) * extent_z
		local min_x = world_x - world_extent_x
		local min_y = world_y - world_extent_y
		local min_z = world_z - world_extent_z
		local max_x = world_x + world_extent_x
		local max_y = world_y + world_extent_y
		local max_z = world_z + world_extent_z

		if min_x < target.min_x then target.min_x = min_x end

		if min_y < target.min_y then target.min_y = min_y end

		if min_z < target.min_z then target.min_z = min_z end

		if max_x > target.max_x then target.max_x = max_x end

		if max_y > target.max_y then target.max_y = max_y end

		if max_z > target.max_z then target.max_z = max_z end

		return
	end

	local function expand_point(x, y, z)
		local transformed_x, transformed_y, transformed_z = matrix:TransformVectorUnpacked(x, y, z)

		if transformed_x < target.min_x then target.min_x = transformed_x end

		if transformed_y < target.min_y then target.min_y = transformed_y end

		if transformed_z < target.min_z then target.min_z = transformed_z end

		if transformed_x > target.max_x then target.max_x = transformed_x end

		if transformed_y > target.max_y then target.max_y = transformed_y end

		if transformed_z > target.max_z then target.max_z = transformed_z end
	end

	expand_point(source.min_x, source.min_y, source.min_z)
	expand_point(source.min_x, source.min_y, source.max_z)
	expand_point(source.min_x, source.max_y, source.min_z)
	expand_point(source.min_x, source.max_y, source.max_z)
	expand_point(source.max_x, source.min_y, source.min_z)
	expand_point(source.max_x, source.min_y, source.max_z)
	expand_point(source.max_x, source.max_y, source.min_z)
	expand_point(source.max_x, source.max_y, source.max_z)
end

local function build_transformed_aabb(source, matrix)
	if not source then return nil end

	if not matrix then return source end

	local out = create_empty_aabb()
	expand_aabb_with_transformed(source, matrix, out)
	return out
end

local function is_managed_visual_child(child)
	return child and (child.VisualOwner ~= nil or child.visual_primitive) or false
end

Visual:StartStorable()
Visual:GetSet("Visible", true)
Visual:GetSet("CastShadows", true)
Visual:GetSet("UseOcclusionCulling", true)
Visual:GetSet("CullDistance", 2000)
Visual:GetSet("ModelPath", "")
Visual:GetSet("MaterialOverride", nil)
Visual:GetSet("AABB", create_empty_aabb())
Visual:EndStorable()
Visual:IsSet("Loading", false)

function Visual:Initialize()
	self.RenderEntries = {}
	self.RenderEntriesDirty = true
	self.LoadGeneration = 0
	refresh_forward_overlay_registry(self)
end

function Visual:SetUseOcclusionCulling(enabled)
	self.UseOcclusionCulling = enabled
	refresh_occlusion_registries(self)
end

function Visual:SetCastShadows(enabled)
	prototype.CommitProperty(self, "CastShadows", enabled)
	mark_shadow_change(self)
	refresh_shadow_registry(self)
	invalidate_scene_acceleration()
end

function Visual:InvalidateRenderEntries()
	self.RenderEntriesDirty = true
	self.HasIgnoreZRenderEntries = false
	self.HasOpaqueRenderEntries = false
	self.WorldAABBCache = nil
	self.WorldAABBCacheMatrix = nil
	self.WorldAABBCacheSource = nil
	self.raycast_primitive_acceleration = nil
	mark_shadow_change(self)
	refresh_forward_overlay_registry(self)
	invalidate_scene_acceleration()
end

function Visual:InvalidateHierarchyState()
	self:InvalidateRenderEntries()
	self:SetAABB(create_empty_aabb())
end

function Visual:CreatePrimitiveEntity(polygon3d, material, name, local_matrix)
	local primitive_entity = Entity.New{
		Name = name or ((self.Owner and self.Owner.Name) or "visual") .. "_primitive",
		Parent = self.Owner,
	}
	primitive_entity.VisualOwner = self
	local transform = primitive_entity:AddComponent("transform")

	if local_matrix then transform:SetFromMatrix(local_matrix) end

	local visual_primitive = primitive_entity:AddComponent("visual_primitive")
	visual_primitive:SetPolygon3D(polygon3d)
	visual_primitive:SetMaterial(material)
	return primitive_entity, visual_primitive
end

function Visual:RemovePrimitives()
	local to_remove = {}

	for _, child in ipairs(self.Owner:GetChildren()) do
		if is_managed_visual_child(child) then to_remove[#to_remove + 1] = child end
	end

	for i = 1, #to_remove do
		to_remove[i]:Remove()
	end

	self:InvalidateHierarchyState()
end

function Visual:MakeError()
	self:RemovePrimitives()
	self:SetLoading(false)
	local poly = Polygon3D.New()
	poly:CreateCube(0.5, 1.0)
	poly:BuildBoundingBox()
	poly:Upload()
	self:CreatePrimitiveEntity(
		poly,
		Material.New{
			AlbedoTexture = Texture.GetFallback(),
			DoubleSided = true,
		},
		((self.Owner and self.Owner.Name) or "visual") .. "_error"
	)
	self:BuildAABB()
end

function Visual:SetModelPath(path)
	self.LoadGeneration = (self.LoadGeneration or 0) + 1
	local load_generation = self.LoadGeneration
	self:RemovePrimitives()
	prototype.CommitProperty(self, "ModelPath", path)
	self:SetLoading(true)

	if path == "" then
		self:SetLoading(false)
		return
	end

	local primitive_index = 0

	model_loader.LoadModel(
		path,
		function()
			if not self:IsValid() or self.LoadGeneration ~= load_generation then
				print("visual became invalid while loading")
				return
			end

			self:SetLoading(false)
			self:BuildAABB()
		end,
		function(data)
			if not self:IsValid() or self.LoadGeneration ~= load_generation then
				print("visual became invalid while loading")
				return
			end

			primitive_index = primitive_index + 1
			self:CreatePrimitiveEntity(
				data.mesh,
				data.material,
				((self.Owner and self.Owner.Name) or "visual") .. "_primitive_" .. primitive_index
			)
		end,
		function(err)
			if not self:IsValid() or self.LoadGeneration ~= load_generation then
				print("visual became invalid while loading: " .. err)
				error(err)
				return
			end

			logf("%s failed to load model %q: %s\n", self, path, err)
			self:MakeError()
		end
	)
end

function Visual:RebuildRenderEntries()
	local entries = {}
	local bounds = create_empty_aabb()
	local has_ignore_z_entries = false
	local has_opaque_entries = false

	for _, child in ipairs(self.Owner:GetChildrenList()) do
		local primitive = child.visual_primitive

		if primitive then
			local polygon3d = primitive:GetPolygon3D()

			if polygon3d then
				local source_aabb = primitive:GetLocalAABB()
				local transform = child.transform
				local material = primitive:GetMaterial()
				local local_matrix = transform and transform:GetLocalMatrix() or nil
				local local_matrix_inverse = local_matrix and local_matrix:GetInverse() or nil
				local local_aabb = build_transformed_aabb(source_aabb, local_matrix)
				entries[#entries + 1] = {
					entity = child,
					primitive = primitive,
					acceleration_owner = primitive,
					polygon3d = polygon3d,
					transform = transform,
					local_matrix = local_matrix,
					local_matrix_inverse = local_matrix_inverse,
					material = material,
					aabb = local_aabb,
					source_aabb = source_aabb,
				}

				if material_ignores_z(material) then
					has_ignore_z_entries = true
				else
					has_opaque_entries = true
				end

				if local_aabb then bounds:Expand(local_aabb) end
			end
		end
	end

	self.RenderEntries = entries
	self.RenderEntriesDirty = false
	self.HasIgnoreZRenderEntries = has_ignore_z_entries
	self.HasOpaqueRenderEntries = has_opaque_entries
	self:SetAABB(bounds)
	refresh_forward_overlay_registry(self)
	return entries
end

function Visual:GetRenderEntries()
	if self.RenderEntriesDirty then return self:RebuildRenderEntries() end

	return self.RenderEntries
end

function Visual:GetPhysicsPrimitives()
	return self:GetRenderEntries()
end

function Visual:BuildAABB()
	self:GetRenderEntries()
	return self:GetAABB()
end

function Visual:GetWorldMatrix()
	if self.Owner and self.Owner.transform then
		return self.Owner.transform:GetWorldMatrix()
	end

	return nil
end

function Visual:GetWorldMatrixInverse()
	if self.Owner and self.Owner.transform then
		return self.Owner.transform:GetWorldMatrixInverse()
	end

	return nil
end

function Visual:GetWorldAABB()
	if self.RenderEntriesDirty then self:RebuildRenderEntries() end

	local world_matrix = self:GetWorldMatrix()
	local local_aabb = self:GetAABB()

	if not local_aabb then return nil end

	if not world_matrix then return local_aabb end

	if
		self.WorldAABBCache and
		self.WorldAABBCacheMatrix == world_matrix and
		self.WorldAABBCacheSource == local_aabb
	then
		return self.WorldAABBCache
	end

	local world_aabb = create_empty_aabb()
	expand_aabb_with_transformed(local_aabb, world_matrix, world_aabb)
	self.WorldAABBCache = world_aabb
	self.WorldAABBCacheMatrix = world_matrix
	self.WorldAABBCacheSource = local_aabb
	return world_aabb
end

function Visual:GetResolvedMaterial(entry)
	return self.MaterialOverride or entry.material or render3d.GetDefaultMaterial()
end

do
	visual.noculling = false
	visual.freeze_culling = false
	visual.occlusion_culling_enabled = true
	visual.shadow_debug_filter = nil
	visual.shadow_debug_log = true
	visual.shadow_debug_frame = -1
	visual.shadow_debug_hits = {}
	visual.shadow_draw_call_stats = setmetatable({}, {__mode = "k"})
	visual.shadow_gpu_culling_stats = setmetatable({}, {__mode = "k"})
	visual.shadow_visible_list_cache = setmetatable({}, {__mode = "k"})
	visual.shadow_prime_seen = setmetatable({}, {__mode = "k"})
	visual.shadow_prime_versions = setmetatable({}, {__mode = "k"})
	visual.shadow_visible_list_version = 0
	visual.shadow_change_version_counter = 0
	visual.shadow_casters = visual.shadow_casters or {}
	visual.forward_overlay_components = visual.forward_overlay_components or {}

	function visual.EnableShadowDrawDebug(filter, should_log)
		visual.shadow_debug_filter = filter == nil and true or filter
		visual.shadow_debug_log = should_log ~= false
		visual.shadow_debug_frame = -1
		visual.shadow_debug_hits = {}
	end

	function visual.DisableShadowDrawDebug()
		visual.shadow_debug_filter = nil
		visual.shadow_debug_hits = {}
	end

	function visual.GetShadowDrawDebugHits()
		return get_shadow_debug_frame_hits()
	end

	function visual.GetShadowDrawCallStats(shadow_map)
		local stats = get_shadow_draw_call_stats_store()
		return stats[shadow_map] and stats[shadow_map].cascades or nil
	end

	function visual.GetShadowGPUCullingStats(shadow_map)
		local stats = get_shadow_gpu_culling_stats_store()
		return stats[shadow_map] and stats[shadow_map].cascades or nil
	end

	function visual.GetAllShadowGPUCullingStats()
		return get_shadow_gpu_culling_stats_store()
	end

	function visual.GetMainGPUCullingStats()
		return get_main_gpu_culling_stats_store()
	end

	commands.Add("dump_main_gpu_culling_stats", function()
		local stats = visual.GetMainGPUCullingStats()
		local counters = render3d.GetInstancingCounters()
		local rejected = render3d.GetInstancingRejectionSummary(counters)

		if not stats.frame then
			print("[main_gpu_culling_stats] no stats recorded yet")
			return
		end

		local gpu_entries_per_draw = stats.gpu_packed_draw_calls > 0 and
			stats.gpu_packed_entry_count / stats.gpu_packed_draw_calls or
			0
		print(
			string.format(
				"[main_gpu_culling_stats] frame=%d instancing_frame=%d",
				stats.frame,
				counters.completed_frame or 0
			)
		)
		print(
			string.format(
				"[main_gpu_culling_stats] visible=%d gpu_packed_entries=%d gpu_packed_draws=%d gpu_active_batches=%d/%d gpu_entries_per_draw=%.2f fallback_visible=%d fallback_submitted=%d cpu_instanced_draws=%d cpu_singleton_draws=%d queue_attempts=%d queued_instances=%d rejected_total=%d rejected_missing_args=%d rejected_missing_pipeline=%d rejected_wireframe=%d rejected_tessellated=%d rejected_vertex_animation=%d rejected_missing_mesh=%d",
				stats.visible_entry_count or 0,
				stats.gpu_packed_entry_count or 0,
				stats.gpu_packed_draw_calls or 0,
				stats.gpu_active_batch_count or 0,
				stats.gpu_total_batch_count or 0,
				gpu_entries_per_draw,
				stats.fallback_visible_entry_count or 0,
				stats.fallback_submitted_entry_count or 0,
				counters.instanced_draws or 0,
				counters.singleton_fallback_draws or 0,
				counters.queue_attempts or 0,
				counters.queued_instances or 0,
				rejected.total or 0,
				rejected.missing_args or 0,
				rejected.missing_pipeline or 0,
				rejected.wireframe or 0,
				rejected.tessellated or 0,
				rejected.vertex_animation or 0,
				rejected.missing_mesh or 0
			)
		)
	end)

	commands.Add("dump_shadow_gpu_culling_stats", function()
		local stats = visual.GetAllShadowGPUCullingStats()
		local rows = {}

		for shadow_map, map_stats in pairs(stats) do
			for cascade_idx, cascade_stats in pairs(map_stats.cascades or {}) do
				rows[#rows + 1] = {
					shadow_map = shadow_map,
					cascade_idx = cascade_idx,
					frame = cascade_stats.frame or 0,
					visible_entry_count = cascade_stats.visible_entry_count or 0,
					fallback_visible_entry_count = cascade_stats.fallback_visible_entry_count or 0,
					gpu_packed_entry_count = cascade_stats.gpu_packed_entry_count or 0,
					gpu_packed_draw_calls = cascade_stats.gpu_packed_draw_calls or 0,
					gpu_active_batch_count = cascade_stats.gpu_active_batch_count or 0,
					gpu_total_batch_count = cascade_stats.gpu_total_batch_count or 0,
					fallback_submitted_entry_count = cascade_stats.fallback_submitted_entry_count or 0,
					fallback_instanced_draw_calls = cascade_stats.fallback_instanced_draw_calls or 0,
					fallback_singleton_draw_calls = cascade_stats.fallback_singleton_draw_calls or 0,
					fallback_missing_world_matrix_count = cascade_stats.fallback_missing_world_matrix_count or 0,
				}
			end
		end

		if not rows[1] then
			print("[shadow_gpu_culling_stats] no stats recorded yet")
			return
		end

		table.sort(rows, function(a, b)
			if a.frame ~= b.frame then return a.frame > b.frame end

			if a.cascade_idx ~= b.cascade_idx then return a.cascade_idx < b.cascade_idx end

			return tostring(a.shadow_map) < tostring(b.shadow_map)
		end)

		local latest_frame = rows[1].frame
		local total_visible = 0
		local total_fallback_visible = 0
		local total_gpu_packed = 0
		local total_gpu_draw_calls = 0
		local total_gpu_active_batches = 0
		local total_gpu_total_batches = 0
		local total_fallback_submitted = 0
		local total_fallback_instanced_draw_calls = 0
		local total_fallback_singleton_draw_calls = 0
		local total_missing_world_matrix = 0
		print(string.format("[shadow_gpu_culling_stats] frame=%d", latest_frame))

		for _, row in ipairs(rows) do
			if row.frame == latest_frame then
				total_visible = total_visible + row.visible_entry_count
				total_fallback_visible = total_fallback_visible + row.fallback_visible_entry_count
				total_gpu_packed = total_gpu_packed + row.gpu_packed_entry_count
				total_gpu_draw_calls = total_gpu_draw_calls + row.gpu_packed_draw_calls
				total_gpu_active_batches = total_gpu_active_batches + row.gpu_active_batch_count
				total_gpu_total_batches = total_gpu_total_batches + row.gpu_total_batch_count
				total_fallback_submitted = total_fallback_submitted + row.fallback_submitted_entry_count
				total_fallback_instanced_draw_calls = total_fallback_instanced_draw_calls + row.fallback_instanced_draw_calls
				total_fallback_singleton_draw_calls = total_fallback_singleton_draw_calls + row.fallback_singleton_draw_calls
				total_missing_world_matrix = total_missing_world_matrix + row.fallback_missing_world_matrix_count
				local gpu_entries_per_draw = row.gpu_packed_draw_calls > 0 and
					row.gpu_packed_entry_count / row.gpu_packed_draw_calls or
					0
				print(
					string.format(
						"[shadow_gpu_culling_stats] map=%s cascade=%d visible=%d gpu_packed_entries=%d gpu_packed_draws=%d gpu_active_batches=%d/%d gpu_entries_per_draw=%.2f fallback_visible=%d fallback_submitted=%d fallback_instanced_draws=%d fallback_singleton_draws=%d missing_world_matrix=%d",
						tostring(row.shadow_map),
						row.cascade_idx,
						row.visible_entry_count,
						row.gpu_packed_entry_count,
						row.gpu_packed_draw_calls,
						row.gpu_active_batch_count,
						row.gpu_total_batch_count,
						gpu_entries_per_draw,
						row.fallback_visible_entry_count,
						row.fallback_submitted_entry_count,
						row.fallback_instanced_draw_calls,
						row.fallback_singleton_draw_calls,
						row.fallback_missing_world_matrix_count
					)
				)
			end
		end

		local total_gpu_entries_per_draw = total_gpu_draw_calls > 0 and total_gpu_packed / total_gpu_draw_calls or 0
		print(
			string.format(
				"[shadow_gpu_culling_stats] total visible=%d gpu_packed_entries=%d gpu_packed_draws=%d gpu_active_batches=%d/%d gpu_entries_per_draw=%.2f fallback_visible=%d fallback_submitted=%d fallback_instanced_draws=%d fallback_singleton_draws=%d missing_world_matrix=%d",
				total_visible,
				total_gpu_packed,
				total_gpu_draw_calls,
				total_gpu_active_batches,
				total_gpu_total_batches,
				total_gpu_entries_per_draw,
				total_fallback_visible,
				total_fallback_submitted,
				total_fallback_instanced_draw_calls,
				total_fallback_singleton_draw_calls,
				total_missing_world_matrix
			)
		)
	end)

	local function get_shadow_tree_volume_change_version(query_aabb)
		local acceleration = ensure_scene_acceleration()

		if not (acceleration and acceleration.shadow_tree and acceleration.shadow_tree.root) then
			return 0
		end

		local tree = acceleration.shadow_tree
		local node_stack = tree.traversal_context and tree.traversal_context.node_stack or {}
		node_stack[1] = tree.root
		local stack_size = 1
		local max_version = 0

		while stack_size > 0 do
			local node = node_stack[stack_size]
			node_stack[stack_size] = nil
			stack_size = stack_size - 1

			if is_aabb_intersecting(node.aabb, query_aabb) then
				if (node.max_shadow_change_version or 0) > max_version then
					if node.first then
						for i = node.first, node.last do
							local item = tree.components[i]

							if is_aabb_intersecting(item.world_aabb, query_aabb) then
								max_version = math.max(max_version, item.shadow_change_version or 0)
							end
						end
					else
						if node.right then
							stack_size = stack_size + 1
							node_stack[stack_size] = node.right
						end

						if node.left then
							stack_size = stack_size + 1
							node_stack[stack_size] = node.left
						end
					end
				end
			end
		end

		return max_version
	end

	function visual.TouchShadowChange(component)
		mark_shadow_change(component)
	end

	function visual.GetShadowVolumeChangeVersion(query_aabb)
		local acceleration = ensure_scene_acceleration()
		local max_version = get_shadow_tree_volume_change_version(query_aabb)

		for _, component in ipairs(acceleration.dynamic_shadow_components or {}) do
			local world_aabb = component:GetWorldAABB()

			if is_aabb_intersecting(world_aabb, query_aabb) then
				max_version = math.max(max_version, component.shadow_change_version or 0)
			end
		end

		for _, component in ipairs(acceleration.non_aabb_shadow_components or {}) do
			local world_aabb = component:GetWorldAABB()

			if not world_aabb or is_aabb_intersecting(world_aabb, query_aabb) then
				max_version = math.max(max_version, component.shadow_change_version or 0)
			end
		end

		return max_version
	end

	local function extract_frustum_planes(proj_view_matrix, out_planes)
		local m = proj_view_matrix
		out_planes[0] = m.m03 + m.m00
		out_planes[1] = m.m13 + m.m10
		out_planes[2] = m.m23 + m.m20
		out_planes[3] = m.m33 + m.m30
		out_planes[4] = m.m03 - m.m00
		out_planes[5] = m.m13 - m.m10
		out_planes[6] = m.m23 - m.m20
		out_planes[7] = m.m33 - m.m30
		out_planes[8] = m.m03 + m.m01
		out_planes[9] = m.m13 + m.m11
		out_planes[10] = m.m23 + m.m21
		out_planes[11] = m.m33 + m.m31
		out_planes[12] = m.m03 - m.m01
		out_planes[13] = m.m13 - m.m11
		out_planes[14] = m.m23 - m.m21
		out_planes[15] = m.m33 - m.m31
		out_planes[16] = m.m02
		out_planes[17] = m.m12
		out_planes[18] = m.m22
		out_planes[19] = m.m32
		out_planes[20] = m.m03 - m.m02
		out_planes[21] = m.m13 - m.m12
		out_planes[22] = m.m23 - m.m22
		out_planes[23] = m.m33 - m.m32

		for i = 0, 20, 4 do
			local a, b, c = out_planes[i], out_planes[i + 1], out_planes[i + 2]
			local len = math.sqrt(a * a + b * b + c * c)

			if len > 0 then
				local inv_len = 1.0 / len
				out_planes[i] = a * inv_len
				out_planes[i + 1] = b * inv_len
				out_planes[i + 2] = c * inv_len
				out_planes[i + 3] = out_planes[i + 3] * inv_len
			end
		end
	end

	local function is_aabb_visible_frustum(aabb, frustum_planes)
		for i = 0, 20, 4 do
			local a, b, c, d = frustum_planes[i], frustum_planes[i + 1], frustum_planes[i + 2], frustum_planes[i + 3]
			local px = a > 0 and aabb.max_x or aabb.min_x
			local py = b > 0 and aabb.max_y or aabb.min_y
			local pz = c > 0 and aabb.max_z or aabb.min_z
			local dist = a * px + b * py + c * pz + d

			if dist < 0 then return false end
		end

		return true
	end

	local function transform_plane(plane_offset, frustum_array, world_matrix, out_offset, out_array)
		local a = frustum_array[plane_offset]
		local b = frustum_array[plane_offset + 1]
		local c = frustum_array[plane_offset + 2]
		local d = frustum_array[plane_offset + 3]
		local m = world_matrix
		out_array[out_offset] = a * m.m00 + b * m.m01 + c * m.m02 + d * m.m03
		out_array[out_offset + 1] = a * m.m10 + b * m.m11 + c * m.m12 + d * m.m13
		out_array[out_offset + 2] = a * m.m20 + b * m.m21 + c * m.m22 + d * m.m23
		out_array[out_offset + 3] = a * m.m30 + b * m.m31 + c * m.m32 + d * m.m33
	end

	local cached_frustum_planes = ffi.new("float[24]")
	local cached_frustum_frame = -1
	local cached_frustum_view = nil
	local cached_frustum_proj = nil
	local cached_cull_camera_frame = -1
	local cached_cull_camera_position = nil

	local function matrix_equals(a, b)
		if not a or not b then return false end

		return a.m00 == b.m00 and
			a.m01 == b.m01 and
			a.m02 == b.m02 and
			a.m03 == b.m03 and
			a.m10 == b.m10 and
			a.m11 == b.m11 and
			a.m12 == b.m12 and
			a.m13 == b.m13 and
			a.m20 == b.m20 and
			a.m21 == b.m21 and
			a.m22 == b.m22 and
			a.m23 == b.m23 and
			a.m30 == b.m30 and
			a.m31 == b.m31 and
			a.m32 == b.m32 and
			a.m33 == b.m33
	end

	local function get_frustum_planes()
		if visual.freeze_culling and cached_frustum_frame >= 0 then
			return cached_frustum_planes
		end

		local current_frame = system.GetFrameNumber()
		local camera = render3d.GetCamera()
		local view = camera:BuildViewMatrix()
		local proj = camera:BuildProjectionMatrix()

		if
			cached_frustum_frame ~= current_frame or
			not matrix_equals(cached_frustum_view, view)
			or
			not matrix_equals(cached_frustum_proj, proj)
		then
			local vp = view * proj
			extract_frustum_planes(vp, cached_frustum_planes)
			cached_frustum_frame = current_frame
			cached_frustum_view = view:Copy()
			cached_frustum_proj = proj:Copy()
		end

		return cached_frustum_planes
	end

	get_cull_camera_position = function()
		local current_frame = system.GetFrameNumber and system.GetFrameNumber() or 0

		if cached_cull_camera_frame == current_frame and cached_cull_camera_position then
			return cached_cull_camera_position
		end

		local camera = render3d.GetCamera()
		cached_cull_camera_position = camera and camera.GetPosition and camera:GetPosition() or nil
		cached_cull_camera_frame = current_frame
		return cached_cull_camera_position
	end

	local function is_aabb_visible_world(world_aabb)
		if visual.noculling then return true end

		if not world_aabb then return true end

		return is_aabb_visible_frustum(world_aabb, get_frustum_planes())
	end

	local function is_aabb_within_cull_distance(world_aabb, cull_distance, camera_position)
		if visual.noculling then return true end

		if not world_aabb or not cull_distance or cull_distance <= 0 then return true end

		camera_position = camera_position or get_cull_camera_position()

		if not camera_position then return true end

		local nearest_x = math.clamp(camera_position.x, world_aabb.min_x, world_aabb.max_x)
		local nearest_y = math.clamp(camera_position.y, world_aabb.min_y, world_aabb.max_y)
		local nearest_z = math.clamp(camera_position.z, world_aabb.min_z, world_aabb.max_z)
		local dx = camera_position.x - nearest_x
		local dy = camera_position.y - nearest_y
		local dz = camera_position.z - nearest_z
		return dx * dx + dy * dy + dz * dz <= cull_distance * cull_distance
	end

	local function is_node_within_cull_distance(node, camera_position)
		return is_aabb_within_cull_distance(
			node and node.aabb or nil,
			node and node.max_cull_distance or nil,
			camera_position
		)
	end

	local function is_world_aabb_visible(component, world_aabb, frustum_planes)
		if visual.noculling then return true end

		if not world_aabb then return true end

		if
			not is_aabb_within_cull_distance(world_aabb, component:GetCullDistance(), get_cull_camera_position())
		then
			return false
		end

		return is_aabb_visible_frustum(world_aabb, frustum_planes or get_frustum_planes())
	end

	local function is_static_item_visible(item, frustum_planes)
		if visual.noculling then return true end

		local world_aabb = item.world_aabb

		if not world_aabb then return true end

		if
			not is_aabb_within_cull_distance(world_aabb, item.cull_distance, get_cull_camera_position())
		then
			return false
		end

		return is_aabb_visible_frustum(world_aabb, frustum_planes)
	end

	local function is_component_visible_in_current_cpu_list(component, frame)
		local acceleration = ensure_scene_acceleration()

		if acceleration.visible_frame ~= frame or not acceleration.visible_components then
			return nil
		end

		for i = 1, #acceleration.visible_components do
			if acceleration.visible_components[i] == component then return true end
		end

		return false
	end

	local function is_component_visible_in_main_gpu_lookup(component, frame)
		local acceleration = ensure_scene_acceleration()
		local cull_result = nil

		if acceleration.visible_frame == frame and acceleration.visible_cull_result then
			cull_result = acceleration.visible_cull_result
		elseif
			acceleration.visible_gpu_cull_result_frame == frame and
			acceleration.visible_gpu_cull_result
		then
			cull_result = acceleration.visible_gpu_cull_result
		else
			return nil
		end

		local entry_count = component.main_gpu_entry_count or 0

		if entry_count <= 0 then return nil end

		local entry_offset = component.main_gpu_entry_offset or 0
		return gpu_culling.IsAnyVisibleEntryInRange(cull_result, entry_offset, entry_count, true)
	end

	local function is_component_frustum_culled(component)
		local frame = system.GetFrameNumber and system.GetFrameNumber() or 0
		local gpu_visible = is_component_visible_in_main_gpu_lookup(component, frame)

		if gpu_visible ~= nil then return not gpu_visible end

		local cpu_visible = is_component_visible_in_current_cpu_list(component, frame)

		if cpu_visible ~= nil then return not cpu_visible end

		if not component.Visible then return true end

		if not component:GetRenderEntries()[1] then return false end

		return not is_world_aabb_visible(component, component:GetWorldAABB(), get_frustum_planes())
	end

	visual.IsComponentFrustumCulled = is_component_frustum_culled

	local function append_visible_component(out, component, frustum_planes)
		if not component.Visible then return out end

		local render_entries = component:GetRenderEntries()

		if not render_entries[1] then return out end

		local world_aabb = component:GetWorldAABB()
		local visible = is_world_aabb_visible(component, world_aabb, frustum_planes)

		if visible then out[#out + 1] = component end

		return out
	end

	local function append_component_render_entries(out, component, payloads)
		for _, entry in ipairs(component:GetRenderEntries() or {}) do
			local index = #out + 1
			local payload = payloads and payloads[index] or nil

			if not payload then
				payload = {
					component = component,
					entry = entry,
				}

				if payloads then payloads[index] = payload end
			else
				payload.component = component
				payload.entry = entry
			end

			out[index] = payload
		end

		return out
	end

	local function append_visible_static_item(out, item, frustum_planes)
		local component = item.component

		if not component.Visible then return out end

		local visible = is_static_item_visible(item, frustum_planes)

		if visible then out[#out + 1] = component end

		return out
	end

	local function append_shadow_visible_component(out, component, shadow_map, cascade_idx, skip_shadow_aabb)
		if not component.CastShadows then return out end

		local render_entries = component:GetRenderEntries()

		if not render_entries[1] then return out end

		if not component:IsWithinCullDistance() then return out end

		if not skip_shadow_aabb then
			local world_aabb = component:GetWorldAABB()

			if world_aabb and not shadow_map:IsWorldAABBVisible(cascade_idx, world_aabb) then
				return out
			end

			if world_aabb and shadow_map:IsWorldAABBTooSmall(cascade_idx, world_aabb) then
				return out
			end
		end

		out[#out + 1] = component
		return out
	end

	local function append_shadow_visible_static_item(out, item, shadow_map, cascade_idx)
		local component = item.component

		if not component.CastShadows then return out end

		if
			not is_aabb_within_cull_distance(item.world_aabb, item.cull_distance, get_cull_camera_position())
		then
			return out
		end

		if not shadow_map:IsWorldAABBVisible(cascade_idx, item.world_aabb) then
			return out
		end

		if shadow_map:IsWorldAABBTooSmall(cascade_idx, item.world_aabb) then
			return out
		end

		out[#out + 1] = component
		return out
	end

	local function append_volume_visible_component(out, component, query_aabb)
		if not component.Visible then return out end

		local render_entries = component:GetRenderEntries()

		if not render_entries[1] then return out end

		if not component:IsWithinCullDistance() then return out end

		local world_aabb = component:GetWorldAABB()

		if world_aabb and query_aabb and not is_aabb_intersecting(world_aabb, query_aabb) then
			return out
		end

		out[#out + 1] = component
		return out
	end

	local function append_volume_visible_static_item(out, item, query_aabb)
		local component = item.component

		if not component.Visible then return out end

		if
			not is_aabb_within_cull_distance(item.world_aabb, item.cull_distance, get_cull_camera_position())
		then
			return out
		end

		if query_aabb and not is_aabb_intersecting(item.world_aabb, query_aabb) then
			return out
		end

		out[#out + 1] = component
		return out
	end

	local function get_shadow_sort_state(component, shadow_map)
		local render_entries = component:GetRenderEntries()
		local first_entry = render_entries[1]
		local material = first_entry and component:GetResolvedMaterial(first_entry) or nil
		local polygon3d = first_entry and first_entry.polygon3d or nil
		return shadow_map:UsesTessellatedMaterial(material) and 1 or 0,
		material and material:GetGUID() or "",
		polygon3d and polygon3d:GetGUID() or "",
		component:GetModelPath() or "",
		component:GetGUID()
	end

	local active_shadow_sort_map

	local function compare_shadow_visible_components(a, b)
		local a_pipeline, a_material, a_polygon, a_model, a_component = get_shadow_sort_state(a, active_shadow_sort_map)
		local b_pipeline, b_material, b_polygon, b_model, b_component = get_shadow_sort_state(b, active_shadow_sort_map)

		if a_pipeline ~= b_pipeline then return a_pipeline < b_pipeline end

		if a_material ~= b_material then return a_material < b_material end

		if a_polygon ~= b_polygon then return a_polygon < b_polygon end

		if a_model ~= b_model then return a_model < b_model end

		return a_component < b_component
	end

	local function sort_shadow_visible_components(out, shadow_map)
		active_shadow_sort_map = shadow_map
		table.sort(out, compare_shadow_visible_components)
		active_shadow_sort_map = nil
		return out
	end

	local function collect_visible_static_components(out, frustum_planes)
		local acceleration = ensure_scene_acceleration()

		if not (acceleration and acceleration.tree and acceleration.tree.root) then
			return out
		end

		local tree = acceleration.tree
		local node_stack = tree.traversal_context and tree.traversal_context.node_stack or {}
		local camera_position = get_cull_camera_position()
		node_stack[1] = tree.root
		local stack_size = 1

		while stack_size > 0 do
			local node = node_stack[stack_size]
			node_stack[stack_size] = nil
			stack_size = stack_size - 1

			if
				is_node_within_cull_distance(node, camera_position) and
				is_aabb_visible_frustum(node.aabb, frustum_planes)
			then
				if node.first then
					for i = node.first, node.last do
						append_visible_static_item(out, tree.components[i], frustum_planes)
					end
				else
					if node.right then
						stack_size = stack_size + 1
						node_stack[stack_size] = node.right
					end

					if node.left then
						stack_size = stack_size + 1
						node_stack[stack_size] = node.left
					end
				end
			end
		end

		return out
	end

	local function collect_shadow_visible_static_components(out, shadow_map, cascade_idx)
		local acceleration = ensure_scene_acceleration()

		if not (acceleration and acceleration.shadow_tree and acceleration.shadow_tree.root) then
			return out
		end

		local tree = acceleration.shadow_tree
		local node_stack = tree.traversal_context and tree.traversal_context.node_stack or {}
		local camera_position = get_cull_camera_position()
		node_stack[1] = tree.root
		local stack_size = 1

		while stack_size > 0 do
			local node = node_stack[stack_size]
			node_stack[stack_size] = nil
			stack_size = stack_size - 1

			if
				is_node_within_cull_distance(node, camera_position) and
				shadow_map:IsWorldAABBVisible(cascade_idx, node.aabb)
			then
				if node.first then
					for i = node.first, node.last do
						append_shadow_visible_static_item(out, tree.components[i], shadow_map, cascade_idx)
					end
				else
					if node.right then
						stack_size = stack_size + 1
						node_stack[stack_size] = node.right
					end

					if node.left then
						stack_size = stack_size + 1
						node_stack[stack_size] = node.left
					end
				end
			end
		end

		return out
	end

	local function collect_volume_visible_static_components(out, query_aabb)
		local acceleration = ensure_scene_acceleration()

		if not (acceleration and acceleration.tree and acceleration.tree.root) then
			return out
		end

		local tree = acceleration.tree
		local node_stack = tree.traversal_context and tree.traversal_context.node_stack or {}
		local camera_position = get_cull_camera_position()
		node_stack[1] = tree.root
		local stack_size = 1

		while stack_size > 0 do
			local node = node_stack[stack_size]
			node_stack[stack_size] = nil
			stack_size = stack_size - 1

			if
				is_node_within_cull_distance(node, camera_position) and
				(
					not query_aabb or
					is_aabb_intersecting(node.aabb, query_aabb)
				)
			then
				if node.first then
					for i = node.first, node.last do
						append_volume_visible_static_item(out, tree.components[i], query_aabb)
					end
				else
					if node.right then
						stack_size = stack_size + 1
						node_stack[stack_size] = node.right
					end

					if node.left then
						stack_size = stack_size + 1
						node_stack[stack_size] = node.left
					end
				end
			end
		end

		return out
	end

	function visual.InvalidateSceneAcceleration()
		invalidate_scene_acceleration()
	end

	local function get_visible_main_gpu_cull_result(include_visible_entry_indices)
		local acceleration = ensure_scene_acceleration()
		local current_frame = system.GetFrameNumber and system.GetFrameNumber() or 0
		local read_visible_entry_indices = include_visible_entry_indices ~= false
		local cached_result = acceleration.visible_gpu_cull_result

		if
			acceleration.visible_gpu_cull_result_frame == current_frame and
			cached_result and
			(
				not read_visible_entry_indices or
				cached_result.visible_entry_indices_ready
			)
		then
			return gpu_culling.GetSceneDataset(), cached_result
		end

		if not gpu_culling.IsEnabled() or visual.noculling then return nil, nil end

		local camera = render3d.GetCamera()
		local dataset = gpu_culling.GetSceneDataset()

		if not dataset then return nil, nil end

		local cull_result = gpu_culling.RunMainViewFrustumCulling(
			camera:BuildViewMatrix() * camera:BuildProjectionMatrix(),
			camera:GetPosition(),
			nil,
			read_visible_entry_indices
		)

		if cull_result then
			acceleration.visible_gpu_cull_result = cull_result
			acceleration.visible_gpu_cull_result_frame = current_frame
		end

		return dataset, cull_result
	end

	function visual.GetVisibleVisuals()
		local current_frame = system.GetFrameNumber and system.GetFrameNumber() or 0
		local acceleration = ensure_scene_acceleration()

		if acceleration.visible_frame == current_frame then
			if
				acceleration.visible_cull_result and
				acceleration.visible_cull_result.visible_entry_indices_ready
			then
				local dataset = gpu_culling.GetSceneDataset()
				local visible_entry_index_ptr, visible_entry_count = gpu_culling.GetVisibleEntrySpan(acceleration.visible_cull_result, true)
				return dataset and dataset.main_entries or nil,
				visible_entry_index_ptr,
				visible_entry_count,
				acceleration.visible_cull_result
			end

			if acceleration.visible_components then
				return acceleration.visible_components, nil, 0, nil
			end
		end

		local frustum_planes = get_frustum_planes()
		local out = acceleration.visible_components or {}
		table.clear(out)

		if gpu_culling.IsEnabled() and not visual.noculling then
			local dataset, cull_result = get_visible_main_gpu_cull_result(true)

			if cull_result then
				local visible_entry_index_ptr, visible_entry_count = gpu_culling.GetVisibleEntrySpan(cull_result, true)
				acceleration.visible_frame = current_frame
				acceleration.visible_cull_result = cull_result
				acceleration.visible_components = nil
				acceleration.visible_render_entries = nil
				acceleration.visible_render_entries_frame = nil
				return dataset.main_entries,
				visible_entry_index_ptr,
				visible_entry_count,
				cull_result
			end
		end

		collect_visible_static_components(out, frustum_planes)

		for _, component in ipairs(acceleration.dynamic_components or {}) do
			append_visible_component(out, component, frustum_planes)
		end

		acceleration.visible_frame = current_frame
		acceleration.visible_cull_result = nil
		acceleration.visible_components = out
		acceleration.visible_render_entries = nil
		acceleration.visible_render_entries_frame = nil
		return out, nil, 0, nil
	end

	function visual.GetVisibleRenderEntries()
		local current_frame = system.GetFrameNumber and system.GetFrameNumber() or 0
		local acceleration = ensure_scene_acceleration()

		if
			acceleration.visible_render_entries_frame == current_frame and
			acceleration.visible_render_entries
		then
			return acceleration.visible_render_entries
		end

		visual.GetVisibleVisuals()
		local out = acceleration.visible_render_entries or {}
		local payloads = acceleration.visible_render_entry_payloads or {}
		table.clear(out)
		local dataset = gpu_culling.GetSceneDataset()
		local cull_result = acceleration.visible_cull_result
		acceleration.visible_render_entry_payloads = payloads

		if dataset and cull_result and cull_result.visible_entry_indices_ready then
			local visible_entry_index_ptr, visible_entry_count = gpu_culling.GetVisibleEntrySpan(cull_result, true)

			for i = 0, visible_entry_count - 1 do
				local entry_index = tonumber(visible_entry_index_ptr[i])
				local record = dataset.main_entries[entry_index + 1]

				if record and record.component and record.source_entry then
					local index = #out + 1
					local payload = payloads[index]

					if not payload then
						payload = {
							component = record.component,
							entry = record.source_entry,
						}
						payloads[index] = payload
					else
						payload.component = record.component
						payload.entry = record.source_entry
					end

					out[index] = payload
				end
			end
		end

		return out
	end

	function visual.GetVisibleMainGPUEntries()
		local read_visible_entry_indices = test_helper.GetCurrentRunningTestName and
			test_helper.GetCurrentRunningTestName() ~= "" or
			false
		local dataset, cull_result = get_visible_main_gpu_cull_result(read_visible_entry_indices)
		local acceleration = ensure_scene_acceleration()
		local current_frame = system.GetFrameNumber and system.GetFrameNumber() or 0

		if dataset and cull_result then
			local visible_entry_index_ptr, visible_entry_count = gpu_culling.GetVisibleEntrySpan(cull_result, true)
			return dataset.main_entries,
			visible_entry_index_ptr,
			visible_entry_count,
			cull_result
		end

		return nil, nil, 0, nil
	end

	function visual.GetShadowVisibleVisuals(shadow_map, cascade_idx)
		local cache = get_shadow_visible_list_cache(shadow_map, cascade_idx)
		local acceleration = ensure_scene_acceleration()
		local camera_position = get_cull_camera_position()
		local query_aabb = shadow_map.GetCascadeWorldAABB and
			shadow_map:GetCascadeWorldAABB(cascade_idx) or
			nil
		local shadow_volume_change_version = get_cached_shadow_volume_change_version(cache, query_aabb)
		local shadow_visible_list_version = get_shadow_visibility_cache_version()

		if
			can_reuse_shadow_visible_list(
				cache,
				query_aabb,
				camera_position,
				shadow_volume_change_version,
				shadow_visible_list_version
			)
		then
			return cache.list
		end

		local out = cache.list
		table.clear(out)

		if gpu_culling.IsEnabled() and not visual.noculling and query_aabb then
			local dataset, cull_result = get_shadow_gpu_cull_result(shadow_map, cascade_idx, true)

			if dataset and cull_result then
				local candidates = cache.candidates or {}
				local seen = cache.gpu_seen or setmetatable({}, {__mode = "k"})
				table.clear(candidates)
				table.clear(seen)
				cache.candidates = candidates
				cache.gpu_seen = seen
				local entry_index_ptr, entry_count = gpu_culling.GetVisibleEntrySpan(cull_result, true)

				for i = 0, entry_count - 1 do
					local record = dataset.shadow_entries[tonumber(entry_index_ptr[i]) + 1]
					local component = record and record.component or nil

					if component and not seen[component] then
						seen[component] = true
						candidates[#candidates + 1] = component
					end
				end

				for _, component in ipairs(candidates) do
					append_shadow_visible_component(out, component, shadow_map, cascade_idx)
				end

				sort_shadow_visible_components(out, shadow_map)
				update_shadow_visible_list_cache(
					cache,
					query_aabb,
					camera_position,
					shadow_volume_change_version,
					shadow_visible_list_version
				)
				return out
			end
		end

		collect_shadow_visible_static_components(out, shadow_map, cascade_idx)

		for _, component in ipairs(acceleration.dynamic_shadow_components or {}) do
			append_shadow_visible_component(out, component, shadow_map, cascade_idx)
		end

		for _, component in ipairs(acceleration.non_aabb_shadow_components or {}) do
			append_shadow_visible_component(out, component, shadow_map, cascade_idx, true)
		end

		sort_shadow_visible_components(out, shadow_map)
		update_shadow_visible_list_cache(
			cache,
			query_aabb,
			camera_position,
			shadow_volume_change_version,
			shadow_visible_list_version
		)
		return out
	end

	function visual.GetShadowVisibleGPUEntries(shadow_map, cascade_idx)
		local dataset, cull_result = get_shadow_gpu_cull_result(shadow_map, cascade_idx, false)
		local visible_entry_index_ptr, visible_entry_count = gpu_culling.GetVisibleEntrySpan(cull_result, false)

		if dataset and cull_result then
			return dataset.shadow_entries,
			visible_entry_index_ptr,
			visible_entry_count,
			cull_result
		end

		return nil, nil, 0, nil
	end

	function visual.GetShadowVisibleRenderEntries(shadow_map, cascade_idx)
		local cache = get_shadow_visible_list_cache(shadow_map, cascade_idx)
		local camera_position = get_cull_camera_position()
		local query_aabb = shadow_map.GetCascadeWorldAABB and
			shadow_map:GetCascadeWorldAABB(cascade_idx) or
			nil
		local shadow_volume_change_version = get_cached_shadow_volume_change_version(cache, query_aabb)
		local shadow_visible_list_version = get_shadow_visibility_cache_version()

		if
			cache.render_entries_valid and
			can_reuse_shadow_visible_list(
				cache,
				query_aabb,
				camera_position,
				shadow_volume_change_version,
				shadow_visible_list_version
			) and
			cache.render_entries
		then
			return cache.render_entries
		end

		local out = cache.render_entries or {}
		local payloads = cache.render_entry_payloads or {}
		table.clear(out)
		cache.render_entry_payloads = payloads
		local entry_records = nil
		local visible_entry_index_ptr = nil
		local visible_entry_count = 0
		local dataset, cull_result = get_shadow_gpu_cull_result(shadow_map, cascade_idx, true)

		if dataset and cull_result then
			entry_records = dataset.shadow_entries
			visible_entry_index_ptr, visible_entry_count = gpu_culling.GetVisibleEntrySpan(cull_result, true)
		end

		if entry_records and visible_entry_index_ptr then
			for i = 0, visible_entry_count - 1 do
				local entry_index = tonumber(visible_entry_index_ptr[i])
				local record = entry_records[entry_index + 1]

				if record and record.component and record.source_entry then
					local index = #out + 1
					local payload = payloads[index]

					if not payload then
						payload = {
							component = record.component,
							entry = record.source_entry,
						}
						payloads[index] = payload
					else
						payload.component = record.component
						payload.entry = record.source_entry
					end

					out[index] = payload
				end
			end

			cache.render_entries = out
			cache.render_entries_valid = true
			update_shadow_cache_query_state(
				cache,
				query_aabb,
				camera_position,
				shadow_volume_change_version,
				shadow_visible_list_version
			)
			return out
		end

		for _, component in ipairs(visual.GetShadowVisibleVisuals(shadow_map, cascade_idx)) do
			append_component_render_entries(out, component, payloads)
		end

		cache.render_entries = out
		cache.render_entries_valid = true
		update_shadow_cache_query_state(
			cache,
			query_aabb,
			camera_position,
			shadow_volume_change_version,
			shadow_visible_list_version
		)
		return out
	end

	function visual.GetVolumeVisibleVisuals(query_aabb)
		local acceleration = ensure_scene_acceleration()
		local out = {}
		collect_volume_visible_static_components(out, query_aabb)

		for _, component in ipairs(acceleration.dynamic_components or {}) do
			append_volume_visible_component(out, component, query_aabb)
		end

		return out
	end

	function visual.GetAABBVisibleVisuals(query_aabb)
		return visual.GetVolumeVisibleVisuals(query_aabb)
	end

	function visual.GetSceneAccelerationVersion()
		return visual.shadow_visible_list_version or 0
	end

	function visual.IsOcclusionCullingEnabled()
		return visual.occlusion_culling_enabled
	end

	function visual.SetOcclusionCulling(enabled)
		if visual.occlusion_culling_enabled == enabled then return end

		visual.occlusion_culling_enabled = enabled

		if gpu_culling.IsEnabled() and gpu_culling.SetOcclusionMode then
			gpu_culling.SetOcclusionMode(enabled and "hiz" or "disabled")
		end

		for _, component in ipairs(Visual.Instances or {}) do
			if component.UseOcclusionCulling then
				component:SetUseOcclusionCulling(true)
			else
				component.using_conditional_rendering = false
				refresh_occlusion_registries(component)
			end
		end
	end

	function visual.GetOcclusionStats()
		local total = 0
		local with_occlusion = 0
		local frustum_culled = 0
		local submitted_with_conditional = 0

		for _, component in ipairs(Visual.Instances) do
			if component.Visible then
				total = total + 1

				if is_component_frustum_culled(component) then
					frustum_culled = frustum_culled + 1
				end

				if component.UseOcclusionCulling then
					with_occlusion = with_occlusion + 1
				end

				if component.using_conditional_rendering then
					submitted_with_conditional = submitted_with_conditional + 1
				end
			end
		end

		return {
			total = total,
			with_occlusion = with_occlusion,
			frustum_culled = frustum_culled,
			submitted_with_conditional = submitted_with_conditional,
			potentially_occluded = submitted_with_conditional,
			occlusion_enabled = visual.IsOcclusionCullingEnabled(),
		}
	end

	function Visual:IsAABBVisibleLocal()
		if visual.noculling then return true end

		local local_aabb = self:GetAABB()

		if not local_aabb or local_aabb.min_x > local_aabb.max_x then return true end

		local world_aabb = self:GetWorldAABB()

		if not world_aabb then return true end

		return is_world_aabb_visible(self, world_aabb)
	end

	function Visual:IsCulled()
		return is_component_frustum_culled(self)
	end

	function Visual:IsWithinCullDistance()
		if visual.noculling then return true end

		local world_aabb = self:GetWorldAABB()

		if not world_aabb then return true end

		return is_aabb_within_cull_distance(world_aabb, self:GetCullDistance())
	end

	Visual.Library = visual
end

function Visual:HasRenderEntriesForPass(ignore_z, render_entries)
	render_entries = render_entries or self:GetRenderEntries()

	if not render_entries[1] then return false end

	if self.MaterialOverride then
		return material_ignores_z(self.MaterialOverride) == ignore_z
	end

	return ignore_z and self.HasIgnoreZRenderEntries or self.HasOpaqueRenderEntries
end

function Visual:DrawEntriesForPass(ignore_z, upload_constants, render_entries)
	local drew_any = false
	render_entries = render_entries or self:GetRenderEntries()

	for _, entry in ipairs(render_entries) do
		local material = self:GetResolvedMaterial(entry)

		if material_ignores_z(material) == ignore_z then
			local transform = entry.transform
			local world_matrix = transform and transform:GetWorldMatrix() or self:GetWorldMatrix()

			if world_matrix then
				if
					not ignore_z and
					upload_constants == render3d.UploadGBufferConstants and
					not self.using_conditional_rendering and
					render3d.QueueGBufferInstance(entry.polygon3d, material, world_matrix, self:GetModelPath())
				then
					drew_any = true
				else
					render3d.SetWorldMatrix(world_matrix)
					render3d.SetCurrentPolygon3D(entry.polygon3d)
					render3d.SetMaterial(material)
					upload_constants()
					entry.polygon3d:Draw()
				end

				drew_any = true
			end
		end
	end

	return drew_any
end

local function draw_geometry_entry(component, entry)
	local material = component:GetResolvedMaterial(entry)

	if material_ignores_z(material) then return false end

	local transform = entry.transform
	local world_matrix = transform and transform:GetWorldMatrix() or component:GetWorldMatrix()

	if not world_matrix then return false end

	if
		render3d.QueueGBufferInstance(entry.polygon3d, material, world_matrix, component:GetModelPath())
	then
		return true
	end

	render3d.SetWorldMatrix(world_matrix)
	render3d.SetCurrentPolygon3D(entry.polygon3d)
	render3d.SetMaterial(material)
	render3d.UploadGBufferConstants()
	entry.polygon3d:Draw()
	return true
end

local function draw_shadow_entry(component, entry, shadow_map, cascade_idx)
	local transform = entry.transform
	local world_matrix = transform and transform:GetWorldMatrix() or component:GetWorldMatrix()

	if not world_matrix then return false end

	local material = component:GetResolvedMaterial(entry)

	if material then
		material.shadow_debug_force_opaque = shadow_debug_matches(component)
	end

	render3d.SetWorldMatrix(world_matrix)
	render3d.SetCurrentPolygon3D(entry.polygon3d)
	shadow_map:UploadConstants(world_matrix, material, cascade_idx)
	entry.polygon3d:Draw()
	return true
end

function Visual:DrawGeometryPass(render_entries, skip_visibility)
	if not self.Visible then return end

	render_entries = render_entries or self:GetRenderEntries()

	if not render_entries[1] then return end

	if not self:HasRenderEntriesForPass(false, render_entries) then return end

	local cmd = render.GetCommandBuffer()

	if not skip_visibility and not self:IsAABBVisibleLocal() then return end

	self:DrawEntriesForPass(false, render3d.UploadGBufferConstants, render_entries)
end

function Visual:OnDraw3DGeometry()
	return self:DrawGeometryPass()
end

function Visual:DrawForwardOverlayPass(render_entries, skip_visibility)
	if not self.Visible then return end

	render_entries = render_entries or self:GetRenderEntries()

	if not render_entries[1] then return end

	if not self:HasRenderEntriesForPass(true, render_entries) then return end

	if not skip_visibility and not self:IsAABBVisibleLocal() then return end

	self:DrawEntriesForPass(true, render3d.UploadForwardOverlayConstants, render_entries)
end

function Visual:OnDraw3DForwardOverlay()
	return self:DrawForwardOverlayPass()
end

function Visual:DrawShadow(shadow_map, cascade_idx, render_entries, skip_visibility_checks)
	if not self.CastShadows then return end

	render_entries = render_entries or self:GetRenderEntries()

	if not skip_visibility_checks then
		if not self:IsWithinCullDistance() then
			record_shadow_debug_hit(self, cascade_idx, "culled_distance")
			return
		end

		if can_use_shadow_aabb_cull(self, render_entries) then
			local world_aabb = self:GetWorldAABB()

			if world_aabb and not shadow_map:IsWorldAABBVisible(cascade_idx, world_aabb) then
				record_shadow_debug_hit(self, cascade_idx, "culled_aabb")
				return
			end
		end
	end

	local submitted_entries = 0

	for _, entry in ipairs(render_entries) do
		local transform = entry.transform
		local world_matrix = transform and transform:GetWorldMatrix() or self:GetWorldMatrix()

		if world_matrix then
			local material = self:GetResolvedMaterial(entry)

			if material then
				material.shadow_debug_force_opaque = shadow_debug_matches(self)
			end

			render3d.SetWorldMatrix(world_matrix)
			render3d.SetCurrentPolygon3D(entry.polygon3d)
			shadow_map:UploadConstants(world_matrix, material, cascade_idx)
			entry.polygon3d:Draw()
			submitted_entries = submitted_entries + 1
		end
	end

	if submitted_entries > 0 then
		record_shadow_draw_calls(shadow_map, cascade_idx, submitted_entries)
		record_shadow_debug_hit(self, cascade_idx, "submitted", submitted_entries)
	else
		record_shadow_debug_hit(self, cascade_idx, "no_world_matrix")
	end
end

function Visual:DrawProbeGeometry(lightprobes)
	if not self.Visible then return end

	if not self:IsWithinCullDistance() then return end

	for _, entry in ipairs(self:GetRenderEntries()) do
		local transform = entry.transform
		local world_matrix = transform and transform:GetWorldMatrix() or self:GetWorldMatrix()

		if world_matrix then
			render3d.SetWorldMatrix(world_matrix)
			render3d.SetCurrentPolygon3D(entry.polygon3d)
			render3d.SetMaterial(self:GetResolvedMaterial(entry))
			lightprobes.UploadConstants()
			entry.polygon3d:Draw()
		end
	end
end

function Visual:DrawVoxelGeometry(scene_voxelizer, clipmap_index, submit_entry)
	if not self.Visible then return 0 end

	if not self:IsWithinCullDistance() then return 0 end

	local submitted_entries = 0

	for _, entry in ipairs(self:GetRenderEntries()) do
		local transform = entry.transform
		local world_matrix = transform and transform:GetWorldMatrix() or self:GetWorldMatrix()

		if world_matrix then
			local material = self:GetResolvedMaterial(entry)

			if scene_voxelizer.ShouldVoxelizeMaterial(material) then
				render3d.SetWorldMatrix(world_matrix)
				render3d.SetCurrentPolygon3D(entry.polygon3d)
				render3d.SetMaterial(material)

				if submit_entry then
					submit_entry(scene_voxelizer, clipmap_index, self, entry, world_matrix, material)
				end

				submitted_entries = submitted_entries + 1
			end
		end
	end

	return submitted_entries
end

function Visual:OnChildAdd()
	self:InvalidateHierarchyState()
end

function Visual:OnChildRemove()
	self:InvalidateHierarchyState()
end

function Visual:OnAdd()
	mark_shadow_change(self)
	invalidate_scene_acceleration()
	refresh_visual_registries(self)
end

function Visual:OnRemove()
	registry_remove(visual.shadow_casters, "shadow_registry_index", self)
	registry_remove(visual.forward_overlay_components, "forward_overlay_registry_index", self)
	self.RenderEntries = {}
	self:InvalidateRenderEntries()
	invalidate_scene_acceleration()
end

function Visual:OnFirstCreated()
	event.AddListener("Draw3DGeometry", "visual_geometry_draw", function()
		if gpu_culling.IsEnabled() and not visual.noculling then
			local entry_records, visible_entry_index_ptr, visible_entry_count, cull_result = visual.GetVisibleMainGPUEntries()

			if entry_records and visible_entry_index_ptr then
				local gpu_instanced_result = render3d.DrawGPUCulledStaticInstanceBatches(cull_result)
				local gpu_instanced_drawn = gpu_instanced_result.drew_any
				local fallback_submitted_entry_count = 0

				for i = 0, visible_entry_count - 1 do
					local record = entry_records[tonumber(visible_entry_index_ptr[i]) + 1]

					if record and record.component and record.source_entry then
						if gpu_instanced_drawn and record.instanced_batch_index ~= nil then
							goto continue
						end

						if draw_geometry_entry(record.component, record.source_entry) then
							fallback_submitted_entry_count = fallback_submitted_entry_count + 1
						end
					end

					::continue::
				end

				record_main_gpu_culling_stats{
					visible_entry_count = cull_result and
						cull_result.visible_entry_count or
						(
							(
								gpu_instanced_result.submitted_entry_count or
								0
							) + (
								cull_result and
								cull_result.fallback_visible_entry_count or
								0
							)
						),
					fallback_visible_entry_count = cull_result and
						cull_result.fallback_visible_entry_count or
						visible_entry_count,
					gpu_packed_entry_count = gpu_instanced_result.submitted_entry_count or 0,
					gpu_packed_draw_calls = gpu_instanced_result.draw_call_count or 0,
					gpu_active_batch_count = gpu_instanced_result.active_batch_count or 0,
					gpu_total_batch_count = gpu_instanced_result.total_batch_count or 0,
					fallback_submitted_entry_count = fallback_submitted_entry_count,
				}
			else
				for _, visible_entry in ipairs(visual.GetVisibleRenderEntries()) do
					draw_geometry_entry(visible_entry.component, visible_entry.entry)
				end
			end
		else
			local visible_items, visible_entry_index_ptr, visible_entry_count = visual.GetVisibleVisuals()

			if visible_entry_index_ptr then
				local last_component = nil

				for i = 0, visible_entry_count - 1 do
					local record = visible_items[tonumber(visible_entry_index_ptr[i]) + 1]
					local component = record and record.component or nil

					if component and component ~= last_component then
						last_component = component
						component:DrawGeometryPass(nil, true)
					end
				end
			else
				for _, component in ipairs(visible_items) do
					component:DrawGeometryPass(nil, true)
				end
			end
		end
	end)

	event.AddListener("Draw3DForwardOverlay", "visual_forward_overlay_draw", function()
		for _, component in ipairs(visual.forward_overlay_components) do
			if not component:IsCulled() then
				component:DrawForwardOverlayPass(nil, true)
			end
		end
	end)

	event.AddListener("PrimeAllShadowMaterials", "visual_shadow_prime", function(shadow_map)
		local prime_versions = visual.shadow_prime_versions
		local current_visible_list_version = visual.shadow_visible_list_version or 0
		local current_shadow_change_version = visual.shadow_change_version_counter or 0
		local cache = prime_versions[shadow_map]

		if
			cache and
			cache.shadow_visible_list_version == current_visible_list_version and
			cache.shadow_change_version == current_shadow_change_version
		then
			return
		end

		local seen = visual.shadow_prime_seen
		local default_material = render3d.GetDefaultMaterial()
		table.clear(seen)

		for _, component in ipairs(visual.shadow_casters) do
			local material_override = component.MaterialOverride

			for _, entry in ipairs(component:GetRenderEntries()) do
				local material = material_override or entry.material or default_material

				if material and not seen[material] then
					seen[material] = true
					shadow_map:PrimeMaterial(material)
				end
			end
		end

		prime_versions[shadow_map] = {
			shadow_visible_list_version = current_visible_list_version,
			shadow_change_version = current_shadow_change_version,
		}
	end)

	event.AddListener("DrawAllShadows", "visual_shadow_draw", function(shadow_map, cascade_idx)
		reset_shadow_draw_calls(shadow_map, cascade_idx)

		if gpu_culling.IsEnabled() then
			local track_shadow_debug = visual.shadow_debug_filter ~= nil
			local entry_records, visible_entry_index_ptr, visible_entry_count, cull_result = visual.GetShadowVisibleGPUEntries(shadow_map, cascade_idx)
			local draw_result = entry_records and
				visible_entry_index_ptr and
				shadow_map:DrawVisibleEntryIndices(
					entry_records,
					visible_entry_index_ptr,
					visible_entry_count,
					cascade_idx,
					cull_result,
					track_shadow_debug
				) or
				shadow_map:DrawVisibleComponents(
					visual.GetShadowVisibleVisuals(shadow_map, cascade_idx),
					cascade_idx,
					track_shadow_debug
				)
			local submitted_by_component = draw_result.submitted_by_component
			local missing_world_matrix_components = draw_result.missing_world_matrix_components
			local gpu_instanced_entry_count = draw_result.gpu_instanced_entry_count or 0
			local gpu_instanced_draw_calls = draw_result.gpu_instanced_draw_calls or 0
			local gpu_active_batch_count = draw_result.gpu_active_batch_count or 0
			local gpu_total_batch_count = draw_result.gpu_total_batch_count or 0
			local fallback_submitted_entry_count = draw_result.submitted_entry_count or 0
			local missing_world_matrix_count = draw_result.missing_world_matrix_count or 0
			local fallback_visible_entry_count = cull_result and
				cull_result.fallback_visible_entry_count or
				fallback_submitted_entry_count
			local visible_entry_count = cull_result and
				cull_result.visible_entry_count or
				(
					gpu_instanced_entry_count + fallback_visible_entry_count
				)

			if gpu_instanced_entry_count > 0 then
				record_shadow_draw_calls(shadow_map, cascade_idx, gpu_instanced_entry_count)
			end

			if fallback_submitted_entry_count > 0 then
				record_shadow_draw_calls(shadow_map, cascade_idx, fallback_submitted_entry_count)
			end

			if track_shadow_debug then
				for component, count in pairs(submitted_by_component) do
					record_shadow_debug_hit(component, cascade_idx, "submitted", count)
				end
			end

			if
				gpu_instanced_entry_count > 0 and
				visual.shadow_debug_filter ~= nil and
				entry_records and
				cull_result and
				cull_result.visible_entry_indices_ready
			then
				local visible_entry_index_ptr, visible_entry_count = gpu_culling.GetVisibleEntrySpan(cull_result, true)

				for i = 0, visible_entry_count - 1 do
					local entry_index = tonumber(visible_entry_index_ptr[i])
					local record = entry_records[entry_index + 1]

					if record and record.component and record.instanced_batch_index ~= nil then
						record_shadow_debug_hit(record.component, cascade_idx, "submitted", 1)
					end
				end
			end

			if track_shadow_debug then
				for component in pairs(missing_world_matrix_components) do
					record_shadow_debug_hit(component, cascade_idx, "no_world_matrix")
				end
			end

			record_shadow_gpu_culling_stats(
				shadow_map,
				cascade_idx,
				{
					visible_entry_count = visible_entry_count,
					fallback_visible_entry_count = fallback_visible_entry_count,
					gpu_packed_entry_count = gpu_instanced_entry_count,
					gpu_packed_draw_calls = gpu_instanced_draw_calls,
					gpu_active_batch_count = gpu_active_batch_count,
					gpu_total_batch_count = gpu_total_batch_count,
					fallback_submitted_entry_count = fallback_submitted_entry_count,
					fallback_instanced_draw_calls = draw_result.instanced_draws or 0,
					fallback_singleton_draw_calls = draw_result.fallback_draws or 0,
					fallback_missing_world_matrix_count = missing_world_matrix_count,
				}
			)
		else
			for _, component in ipairs(visual.GetShadowVisibleVisuals(shadow_map, cascade_idx)) do
				component:DrawShadow(shadow_map, cascade_idx, nil, true)
			end
		end
	end)

	event.AddListener("DrawProbeGeometry", "visual_probe_draw", function(cmd, lightprobes)
		for _, visual in ipairs(Visual.Instances) do
			visual:DrawProbeGeometry(lightprobes)
		end
	end)
end

function Visual:OnLastRemoved()
	event.RemoveListener("DrawAllShadows", "visual_shadow_draw")
	event.RemoveListener("PrimeAllShadowMaterials", "visual_shadow_prime")
	event.RemoveListener("DrawProbeGeometry", "visual_probe_draw")
end

return Visual:Register()
