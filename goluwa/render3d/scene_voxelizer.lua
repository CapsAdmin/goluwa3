local Vec3 = import("goluwa/structs/vec3.lua")
local AABB = import("goluwa/structs/aabb.lua")
local VoxelGrid = import("goluwa/render3d/voxel_grid.lua")
local scene_voxelizer = library()
local AXES = {"x", "y", "z"}
scene_voxelizer.DEFAULT_CLIPMAP_RESOLUTION = 128
scene_voxelizer.DEFAULT_CLIPMAP_COUNT = 3
scene_voxelizer.DEFAULT_BASE_VOXEL_SIZE = 0.5
scene_voxelizer.DEFAULT_CLIPMAP_SNAP_VOXEL_STRIDE = 1
scene_voxelizer.DEFAULT_BUILD_SLICES_PER_FRAME = 12
scene_voxelizer.DEFAULT_BACKGROUND_BUILD_SLICES_PER_FRAME = 24
scene_voxelizer.DEFAULT_MOVING_MAX_ACTIVE_CLIPMAPS_PER_FRAME = 0
scene_voxelizer.DEFAULT_SETTLED_MAX_ACTIVE_CLIPMAPS_PER_FRAME = 0
scene_voxelizer.DEFAULT_PREFER_EXPOSED_DIRTY_SLICES = true

local function get_half_resolution(clipmap)
	return clipmap.resolution * 0.5
end

local function get_half_world_span(clipmap)
	return clipmap.world_span * 0.5
end

local function build_clipmap_world_aabb(clipmap, origin_override)
	local half_span = get_half_world_span(clipmap)
	local origin = origin_override or clipmap.origin
	return AABB(
		origin.x - half_span,
		origin.y - half_span,
		origin.z - half_span,
		origin.x + half_span,
		origin.y + half_span,
		origin.z + half_span
	)
end

local function get_centered_voxel_coordinates(clipmap, world_position)
	local inv_voxel_size = 1 / clipmap.voxel_size
	local half_resolution = get_half_resolution(clipmap)
	return (world_position.x - clipmap.origin.x) * inv_voxel_size + half_resolution,
	(world_position.y - clipmap.origin.y) * inv_voxel_size + half_resolution,
	(world_position.z - clipmap.origin.z) * inv_voxel_size + half_resolution
end

local function get_clipmap_resolution(self, index)
	local resolutions = self.clipmap_resolutions

	if resolutions and resolutions[index] then return resolutions[index] end

	return self.base_resolution
end

local function get_clipmap_voxel_size(self, index)
	local sizes = self.clipmap_voxel_sizes

	if sizes and sizes[index] then return sizes[index] end

	return self.base_voxel_size * 2 ^ (index - 1)
end

local function snap_axis(value, voxel_size)
	return math.floor(value / voxel_size) * voxel_size
end

local function build_snapped_origin(camera_position, voxel_size)
	return Vec3(
		snap_axis(camera_position.x, voxel_size),
		snap_axis(camera_position.y, voxel_size),
		snap_axis(camera_position.z, voxel_size)
	)
end

local function get_visual_library()
	local Visual = import.loaded["goluwa/ecs/components/3d/visual.lua"] or
		import("goluwa/ecs/components/3d/visual.lua")
	return Visual and Visual.Library or nil
end

local function create_grid(name, clipmap_count, get_resolution, get_voxel_size, target_groups)
	return VoxelGrid.New{
		name = name,
		clipmap_count = clipmap_count,
		get_resolution = get_resolution,
		get_voxel_size = get_voxel_size,
		target_groups = target_groups,
	}:Reset()
end

local function refresh_clipmap_resource_views(clipmap)
	local scene_resources = clipmap.scene_grid_clipmap and clipmap.scene_grid_clipmap.resources or nil
	clipmap.resources = {
		axis_targets = scene_resources and scene_resources.active or nil,
		scroll_targets = scene_resources and scene_resources.build or nil,
	}
end

local function refresh_clipmap_views(self, clipmap)
	local scene_grid_clipmap = clipmap.scene_grid_clipmap
	clipmap.resolution = scene_grid_clipmap.resolution
	clipmap.voxel_size = scene_grid_clipmap.voxel_size
	clipmap.world_span = scene_grid_clipmap.world_span
	clipmap.origin = scene_grid_clipmap.origin
	clipmap.build_origin = scene_grid_clipmap.build_origin
	clipmap.world_aabb = scene_grid_clipmap.world_aabb
	clipmap.build_world_aabb = scene_grid_clipmap.build_world_aabb
	refresh_clipmap_resource_views(clipmap)
end

local function set_scene_origin(self, clipmap, origin)
	self.scene_grid:SetOrigin(clipmap.index, origin)
	refresh_clipmap_views(self, clipmap)
end

local function set_scene_build_origin(self, clipmap, origin)
	self.scene_grid:SetBuildOrigin(clipmap.index, origin)
	refresh_clipmap_views(self, clipmap)
end

local function get_target_debug_id(target)
	if not target then return "nil" end

	return tostring(target.texture or target.sample_view or target)
end

local function complete_target_content_version(clipmap, group_name)
	local version = clipmap.next_content_version or 1
	clipmap.next_content_version = version + 1

	if group_name == "build" then
		clipmap.build_content_version = version
	else
		clipmap.active_content_version = version
	end

	return version
end

local function swap_target_content_versions(clipmap)
	clipmap.active_content_version, clipmap.build_content_version = clipmap.build_content_version, clipmap.active_content_version
end

local function origins_match(a, b)
	return a and b and a.x == b.x and a.y == b.y and a.z == b.z
end

local function ensure_clipmap_state(self, index)
	local clipmap = self.clipmaps[index]

	if clipmap then return clipmap end

	local scene_grid_clipmap = self.scene_grid:EnsureClipmap(index)
	clipmap = {
		index = index,
		scene_grid_clipmap = scene_grid_clipmap,
		previous_origin = nil,
		delta = Vec3(0, 0, 0),
		dirty = true,
		full_rebuild = true,
		axis_full_rebuild = {x = true, y = true, z = true},
		building_into_scroll = false,
		has_valid_data = false,
		clear_dirty_slices = false,
		dirty_slabs = {x = 0, y = 0, z = 0},
		dirty_slice_masks = {x = {}, y = {}, z = {}},
		dirty_slice_regions = {x = {}, y = {}, z = {}},
		pending_dirty_slices = nil,
		pending_clear = true,
		build_target_cleared = false,
		pending_scroll = nil,
		build_scroll_ready = false,
		active_content_version = 0,
		build_content_version = 0,
		next_content_version = 1,
		last_handoff_mode = "init",
		last_handoff_origin = Vec3(0, 0, 0),
		last_handoff_active_version = 0,
		last_handoff_build_version = 0,
		last_handoff_rescheduled = false,
		build_selected_this_frame = true,
	}
	refresh_clipmap_views(self, clipmap)
	self.clipmaps[index] = clipmap
	return clipmap
end

local function sync_dirty_slabs_from_masks(clipmap)
	for _, axis_name in ipairs(AXES) do
		local mask = clipmap.dirty_slice_masks[axis_name]
		local count = 0

		for slice = 0, clipmap.resolution - 1 do
			if mask[slice] then count = count + 1 end
		end

		clipmap.dirty_slabs[axis_name] = count
	end
end

local function clear_dirty_slice_masks(clipmap)
	for _, axis_name in ipairs(AXES) do
		clipmap.dirty_slice_masks[axis_name] = {}
		clipmap.dirty_slice_regions[axis_name] = {}
	end

	clipmap.pending_dirty_slices = nil
	sync_dirty_slabs_from_masks(clipmap)
end

local function clip_repair_rect(resolution, x, y, w, h)
	local x0 = math.max(0, x)
	local y0 = math.max(0, y)
	local x1 = math.min(resolution, x + w)
	local y1 = math.min(resolution, y + h)

	if x1 <= x0 or y1 <= y0 then return nil end

	return {
		x = x0,
		y = y0,
		w = x1 - x0,
		h = y1 - y0,
	}
end

local function copy_slice_region(region)
	if not region then return nil end

	if region.full then return {full = true} end

	local copy = {full = false, rects = {}}

	for i, rect in ipairs(region.rects or {}) do
		copy.rects[i] = {
			x = rect.x,
			y = rect.y,
			w = rect.w,
			h = rect.h,
		}
	end

	return copy
end

local function mark_dirty_slice_full(clipmap, axis_name, slice)
	if slice < 0 or slice >= clipmap.resolution then return end

	clipmap.dirty_slice_masks[axis_name][slice] = true
	clipmap.dirty_slice_regions[axis_name][slice] = {full = true}
	clipmap.pending_dirty_slices = nil
end

local function mark_dirty_slice_rect(clipmap, axis_name, slice, x, y, w, h)
	if slice < 0 or slice >= clipmap.resolution then return end

	local rect = clip_repair_rect(clipmap.resolution, x, y, w, h)

	if not rect then return end

	clipmap.dirty_slice_masks[axis_name][slice] = true
	local region = clipmap.dirty_slice_regions[axis_name][slice]

	if region and region.full then return end

	if not region then
		region = {full = false, rects = {}}
		clipmap.dirty_slice_regions[axis_name][slice] = region
	end

	region.rects[#region.rects + 1] = rect
	clipmap.pending_dirty_slices = nil
end

local function get_axis_scroll_offsets(axis_name, delta)
	if axis_name == "x" then return delta.z, delta.y, -delta.x end

	if axis_name == "y" then return delta.x, -delta.z, -delta.y end

	return delta.x, delta.y, -delta.z
end

local function shift_slice_region(clipmap, region, offset_x, offset_y)
	if not region then return nil end

	if region.full then return {full = true} end

	local shifted = {full = false, rects = {}}

	for _, rect in ipairs(region.rects or {}) do
		local shifted_rect = clip_repair_rect(clipmap.resolution, rect.x + offset_x, rect.y + offset_y, rect.w, rect.h)

		if shifted_rect then shifted.rects[#shifted.rects + 1] = shifted_rect end
	end

	if #shifted.rects == 0 then return nil end

	return shifted
end

local function get_preserved_slice_span(resolution, layer_offset)
	local count = resolution - math.abs(layer_offset)

	if count <= 0 then return nil end

	local start_slice = math.max(0, layer_offset)
	return start_slice, start_slice + count - 1
end

local function build_exposed_plane_rects(resolution, offset_x, offset_y)
	local rects = {}

	if offset_x > 0 then
		rects[#rects + 1] = {x = 0, y = 0, w = offset_x, h = resolution}
	elseif offset_x < 0 then
		rects[#rects + 1] = {x = resolution + offset_x, y = 0, w = -offset_x, h = resolution}
	end

	if offset_y > 0 then
		rects[#rects + 1] = {x = 0, y = 0, w = resolution, h = offset_y}
	elseif offset_y < 0 then
		rects[#rects + 1] = {x = 0, y = resolution + offset_y, w = resolution, h = -offset_y}
	end

	return rects
end

local function transport_axis_dirty_repairs(clipmap, axis_name)
	local offset_x, offset_y, layer_offset = get_axis_scroll_offsets(axis_name, clipmap.delta)
	local previous_masks = clipmap.dirty_slice_masks[axis_name]
	local previous_regions = clipmap.dirty_slice_regions[axis_name]
	clipmap.dirty_slice_masks[axis_name] = {}
	clipmap.dirty_slice_regions[axis_name] = {}

	for slice in pairs(previous_masks) do
		local shifted_slice = slice + layer_offset

		if shifted_slice >= 0 and shifted_slice < clipmap.resolution then
			local shifted_region = shift_slice_region(clipmap, previous_regions[slice], offset_x, offset_y)

			if shifted_region then
				clipmap.dirty_slice_masks[axis_name][shifted_slice] = true
				clipmap.dirty_slice_regions[axis_name][shifted_slice] = shifted_region
			end
		end
	end

	local repair_rects = build_exposed_plane_rects(clipmap.resolution, offset_x, offset_y)
	local start_slice, end_slice = get_preserved_slice_span(clipmap.resolution, layer_offset)

	if not start_slice then
		for slice = 0, clipmap.resolution - 1 do
			mark_dirty_slice_full(clipmap, axis_name, slice)
		end

		return
	end

	for slice = 0, start_slice - 1 do
		mark_dirty_slice_full(clipmap, axis_name, slice)
	end

	for slice = end_slice + 1, clipmap.resolution - 1 do
		mark_dirty_slice_full(clipmap, axis_name, slice)
	end

	if start_slice and #repair_rects > 0 then
		for slice = start_slice, end_slice do
			local region = clipmap.dirty_slice_regions[axis_name][slice]

			if not (region and region.full) then
				for _, rect in ipairs(repair_rects) do
					mark_dirty_slice_rect(clipmap, axis_name, slice, rect.x, rect.y, rect.w, rect.h)
				end
			end
		end
	end
end

local function mark_all_dirty_slices(clipmap)
	for _, axis_name in ipairs(AXES) do
		for slice = 0, clipmap.resolution - 1 do
			mark_dirty_slice_full(clipmap, axis_name, slice)
		end
	end

	clipmap.pending_dirty_slices = nil
	sync_dirty_slabs_from_masks(clipmap)
end

local function has_any_dirty_slices(clipmap)
	for _, axis_name in ipairs(AXES) do
		if next(clipmap.dirty_slice_masks[axis_name]) ~= nil then return true end
	end

	return false
end

local function build_dirty_slice_list(clipmap, axis_name)
	if
		scene_voxelizer.prefer_exposed_dirty_slices == true and
		clipmap.building_into_scroll
	then
		local full_slices = {}
		local partial_slices = {}
		local mask = clipmap.dirty_slice_masks[axis_name]
		local regions = clipmap.dirty_slice_regions[axis_name]

		for slice = 0, clipmap.resolution - 1 do
			if mask[slice] then
				local region = regions[slice]

				if region and region.full then
					full_slices[#full_slices + 1] = slice
				else
					partial_slices[#partial_slices + 1] = slice
				end
			end
		end

		for i = 1, #partial_slices do
			full_slices[#full_slices + 1] = partial_slices[i]
		end

		return full_slices
	end

	local slices = {}
	local mask = clipmap.dirty_slice_masks[axis_name]

	for slice = 0, clipmap.resolution - 1 do
		if mask[slice] then slices[#slices + 1] = slice end
	end

	return slices
end

local function shift_dirty_slice_mask(mask, resolution, delta)
	local shifted = {}

	for slice = 0, resolution - 1 do
		if mask[slice] then
			local shifted_slice = slice - delta

			if shifted_slice >= 0 and shifted_slice < resolution then
				shifted[shifted_slice] = true
			end
		end
	end

	return shifted
end

local function transport_dirty_slices(clipmap)
	clipmap.clear_dirty_slices = false

	for _, axis_name in ipairs(AXES) do
		transport_axis_dirty_repairs(clipmap, axis_name)
	end

	clipmap.pending_dirty_slices = nil
	sync_dirty_slabs_from_masks(clipmap)
end

local function round_delta_to_voxels(delta)
	if delta >= 0 then return math.floor(delta + 0.5) end

	return math.ceil(delta - 0.5)
end

local function schedule_incremental_scroll_rebuild(self, clipmap, target_origin)
	set_scene_build_origin(self, clipmap, target_origin)
	local delta_x = (target_origin.x - clipmap.origin.x) / clipmap.voxel_size
	local delta_y = (target_origin.y - clipmap.origin.y) / clipmap.voxel_size
	local delta_z = (target_origin.z - clipmap.origin.z) / clipmap.voxel_size
	clipmap.delta.x = round_delta_to_voxels(delta_x)
	clipmap.delta.y = round_delta_to_voxels(delta_y)
	clipmap.delta.z = round_delta_to_voxels(delta_z)
	clipmap.dirty = true
	clipmap.full_rebuild = false
	clipmap.axis_full_rebuild.x = false
	clipmap.axis_full_rebuild.y = false
	clipmap.axis_full_rebuild.z = false
	clipmap.build_selected_this_frame = true
	clipmap.building_into_scroll = true
	clipmap.pending_clear = false
	clipmap.build_target_cleared = false
	clipmap.pending_scroll = {
		delta = Vec3(clipmap.delta.x, clipmap.delta.y, clipmap.delta.z),
	}
	clipmap.build_scroll_ready = false
	transport_dirty_slices(clipmap)
end

local function reset_pending_build_state(clipmap)
	clipmap.pending_dirty_slices = nil
	clipmap.pending_clear = clipmap.full_rebuild == true
	clipmap.build_target_cleared = false
	clipmap.pending_scroll = nil
	clipmap.build_scroll_ready = false
end

local function compare_build_selection_candidates(a, b)
	if a.scroll_related ~= b.scroll_related then return a.scroll_related == true end

	if a.distance ~= b.distance then return a.distance < b.distance end

	return a.index < b.index
end

local function update_build_selection()
	local max_active = scene_voxelizer.streaming_is_moving and
		scene_voxelizer.moving_max_active_clipmaps_per_frame or
		scene_voxelizer.settled_max_active_clipmaps_per_frame
	local containing_index = scene_voxelizer.GetContainingClipmapIndex and
		scene_voxelizer.GetContainingClipmapIndex(scene_voxelizer.last_camera_position) or
		1
	local candidates = {}

	for index, clipmap in ipairs(scene_voxelizer.clipmaps or {}) do
		clipmap.build_selected_this_frame = false

		if clipmap.dirty then
			candidates[#candidates + 1] = {
				clipmap = clipmap,
				index = index,
				scroll_related = clipmap.building_into_scroll or
					clipmap.pending_scroll ~= nil or
					clipmap.build_scroll_ready == true,
				distance = math.abs(index - (containing_index or 1)),
			}
		end
	end

	if not max_active or max_active <= 0 then
		for _, candidate in ipairs(candidates) do
			candidate.clipmap.build_selected_this_frame = true
		end

		return
	end

	table.sort(candidates, compare_build_selection_candidates)

	for i = 1, math.min(max_active, #candidates) do
		candidates[i].clipmap.build_selected_this_frame = true
	end
end

function scene_voxelizer.ApplyStreamingConfig(config)
	config = config or {}
	local default_build_slices = scene_voxelizer.build_slices_per_frame or
		scene_voxelizer.DEFAULT_BUILD_SLICES_PER_FRAME
	local default_background_slices = scene_voxelizer.background_build_slices_per_frame or
		scene_voxelizer.DEFAULT_BACKGROUND_BUILD_SLICES_PER_FRAME
	scene_voxelizer.moving_build_slices_per_frame = config.moving_build_slices_per_frame or default_build_slices
	scene_voxelizer.moving_background_build_slices_per_frame = config.moving_background_build_slices_per_frame or default_background_slices
	scene_voxelizer.settled_build_slices_per_frame = config.settled_build_slices_per_frame or default_build_slices
	scene_voxelizer.settled_background_build_slices_per_frame = config.settled_background_build_slices_per_frame or default_background_slices
	scene_voxelizer.moving_max_active_clipmaps_per_frame = config.moving_max_active_clipmaps_per_frame ~= nil and
		config.moving_max_active_clipmaps_per_frame or
		scene_voxelizer.DEFAULT_MOVING_MAX_ACTIVE_CLIPMAPS_PER_FRAME
	scene_voxelizer.settled_max_active_clipmaps_per_frame = config.settled_max_active_clipmaps_per_frame ~= nil and
		config.settled_max_active_clipmaps_per_frame or
		scene_voxelizer.DEFAULT_SETTLED_MAX_ACTIVE_CLIPMAPS_PER_FRAME
	scene_voxelizer.prefer_exposed_dirty_slices = config.prefer_exposed_dirty_slices ~= false
	return scene_voxelizer
end

function scene_voxelizer.ResetState(config)
	config = config or {}

	if scene_voxelizer.scene_grid and scene_voxelizer.scene_grid.Shutdown then
		scene_voxelizer.scene_grid:Shutdown()
	end

	scene_voxelizer.enabled = config.enabled ~= false
	scene_voxelizer.base_resolution = config.base_resolution or scene_voxelizer.DEFAULT_CLIPMAP_RESOLUTION
	scene_voxelizer.clipmap_count = config.clipmap_count or scene_voxelizer.DEFAULT_CLIPMAP_COUNT
	scene_voxelizer.base_voxel_size = config.base_voxel_size or scene_voxelizer.DEFAULT_BASE_VOXEL_SIZE
	scene_voxelizer.clipmap_snap_voxel_stride = config.clipmap_snap_voxel_stride or
		scene_voxelizer.DEFAULT_CLIPMAP_SNAP_VOXEL_STRIDE
	scene_voxelizer.build_slices_per_frame = config.build_slices_per_frame or scene_voxelizer.DEFAULT_BUILD_SLICES_PER_FRAME
	scene_voxelizer.background_build_slices_per_frame = config.background_build_slices_per_frame or
		scene_voxelizer.DEFAULT_BACKGROUND_BUILD_SLICES_PER_FRAME
	scene_voxelizer.ApplyStreamingConfig(config)
	scene_voxelizer.clipmap_resolutions = config.clipmap_resolutions
	scene_voxelizer.clipmap_voxel_sizes = config.clipmap_voxel_sizes
	scene_voxelizer.clipmaps = {}
	scene_voxelizer.scene_grid = create_grid(
		"scene voxel grid",
		scene_voxelizer.clipmap_count,
		function(index)
			return get_clipmap_resolution(scene_voxelizer, index)
		end,
		function(index)
			return get_clipmap_voxel_size(scene_voxelizer, index)
		end,
		{
			active = {},
			build = {label_suffix = "scroll"},
		}
	)
	scene_voxelizer.debug_enabled = config.debug_enabled == true
	scene_voxelizer.last_camera_position = Vec3(0, 0, 0)
	scene_voxelizer.streaming_is_moving = false
	scene_voxelizer.frame_stats = {
		updated_clipmaps = 0,
		full_rebuilds = 0,
		incremental_rebuilds = 0,
		voxel_visuals = 0,
		voxel_entries = 0,
		voxel_build_clipmaps = 0,
		voxel_build_axes = 0,
		voxel_build_slices = 0,
		voxel_scroll_inline_clipmaps = 0,
		voxel_scroll_submit_clipmaps = 0,
		voxel_scroll_submissions = 0,
		voxel_scroll_submit_waits = 0,
	}

	for index = 1, scene_voxelizer.clipmap_count do
		ensure_clipmap_state(scene_voxelizer, index)
	end

	return scene_voxelizer
end

function scene_voxelizer.SetEnabled(enabled)
	scene_voxelizer.enabled = enabled and true or false
end

function scene_voxelizer.IsEnabled()
	return scene_voxelizer.enabled ~= false
end

function scene_voxelizer.GetClipmaps()
	return scene_voxelizer.clipmaps or {}
end

function scene_voxelizer.GetClipmap(index)
	return scene_voxelizer.clipmaps and scene_voxelizer.clipmaps[index] or nil
end

function scene_voxelizer.EnsureClipmapResources(index)
	local clipmap = scene_voxelizer.GetClipmap(index)

	if not clipmap then return nil end

	scene_voxelizer.scene_grid:EnsureResources(index)
	refresh_clipmap_views(scene_voxelizer, clipmap)
	return clipmap.resources
end

function scene_voxelizer.GetClipmapAxisTarget(index, axis_name)
	scene_voxelizer.EnsureClipmapResources(index)
	return scene_voxelizer.scene_grid:GetAxisTarget(index, "active", axis_name)
end

function scene_voxelizer.GetClipmapBuildAxisTarget(index, axis_name)
	local clipmap = scene_voxelizer.GetClipmap(index)
	scene_voxelizer.EnsureClipmapResources(index)

	if not clipmap then return nil end

	if clipmap and clipmap.building_into_scroll then
		return scene_voxelizer.scene_grid:GetAxisTarget(index, "build", axis_name)
	end

	return scene_voxelizer.scene_grid:GetAxisTarget(index, "active", axis_name)
end

function scene_voxelizer.GetClipmapScrollTarget(index, axis_name)
	scene_voxelizer.EnsureClipmapResources(index)
	return scene_voxelizer.scene_grid:GetAxisTarget(index, "build", axis_name)
end

function scene_voxelizer.GetClipmapLightingAxisTarget(index, axis_name)
	local clipmap = scene_voxelizer.GetClipmap(index)
	scene_voxelizer.EnsureClipmapResources(index)

	if not clipmap then return nil end

	if clipmap.build_scroll_ready then
		return scene_voxelizer.scene_grid:GetAxisTarget(index, "build", axis_name)
	end

	return scene_voxelizer.scene_grid:GetAxisTarget(index, "active", axis_name)
end

function scene_voxelizer.GetClipmapLightingOrigin(index)
	local clipmap = scene_voxelizer.GetClipmap(index)

	if not clipmap then return nil end

	if clipmap.build_scroll_ready then return clipmap.build_origin end

	return clipmap.origin
end

function scene_voxelizer.SwapClipmapAxisTarget(index, axis_name)
	scene_voxelizer.EnsureClipmapResources(index)
	scene_voxelizer.scene_grid:SwapAxisTargets(index, "active", "build", axis_name)
end

function scene_voxelizer.SwapClipmapBuildResults(index)
	local clipmap = scene_voxelizer.GetClipmap(index)

	if not clipmap or not clipmap.building_into_scroll then
		if clipmap then
			clipmap.has_valid_data = true
			clipmap.build_scroll_ready = false
		end

		return
	end

	for _, axis_name in ipairs({"x", "y", "z"}) do
		scene_voxelizer.SwapClipmapAxisTarget(index, axis_name)
	end

	clipmap.building_into_scroll = false
	clipmap.has_valid_data = true
	clipmap.build_scroll_ready = false
end

function scene_voxelizer.GetClipmapDirtySliceRange(index, axis_name)
	local clipmap = scene_voxelizer.GetClipmap(index)

	if not clipmap then return nil end

	local slices = build_dirty_slice_list(clipmap, axis_name)

	if #slices == 0 then return nil end

	return {
		start_slice = slices[1],
		end_slice = slices[#slices],
		count = #slices,
		slices = slices,
	}
end

function scene_voxelizer.GetClipmapDirtySliceRepair(index, axis_name, slice)
	local clipmap = scene_voxelizer.GetClipmap(index)

	if not clipmap then return nil end

	return copy_slice_region(clipmap.dirty_slice_regions[axis_name][slice])
end

function scene_voxelizer.ForEachDirtySlice(index, axis_name, callback)
	local dirty_range = scene_voxelizer.GetClipmapDirtySliceRange(index, axis_name)

	if not dirty_range then return 0 end

	for _, slice in ipairs(dirty_range.slices) do
		callback(slice, dirty_range)
	end

	return dirty_range.count
end

function scene_voxelizer.ForEachDirtyAxisTarget(index, slice_budget, callback)
	if type(slice_budget) == "function" then
		callback = slice_budget
		slice_budget = scene_voxelizer.build_slices_per_frame
	end

	local clipmap = scene_voxelizer.GetClipmap(index)

	if not clipmap or not clipmap.dirty then return 0, 0, false end

	if (slice_budget or 0) <= 0 then return 0, 0, false end

	scene_voxelizer.EnsureClipmapResources(index)
	local pending_slices = clipmap.pending_dirty_slices

	if not pending_slices then
		pending_slices = {}

		for _, axis_name in ipairs(AXES) do
			local dirty_range = scene_voxelizer.GetClipmapDirtySliceRange(index, axis_name)

			if dirty_range then
				pending_slices[axis_name] = {
					slices = dirty_range.slices,
					next_index = 1,
				}
			end
		end

		clipmap.pending_dirty_slices = pending_slices
	end

	local dirty_axes = 0
	local dirty_slices = 0
	local remaining_slices = math.max(math.floor(slice_budget or scene_voxelizer.build_slices_per_frame or 1), 1)
	local built_axes = {}

	while remaining_slices > 0 do
		local built_any_slice = false

		for _, axis_name in ipairs(AXES) do
			local target = scene_voxelizer.GetClipmapBuildAxisTarget(index, axis_name)
			local pending = pending_slices[axis_name]
			local slices = pending and pending.slices or nil
			local next_index = pending and pending.next_index or nil

			if target and slices and next_index and next_index <= #slices then
				local slice = slices[next_index]
				pending.next_index = next_index + 1
				callback(axis_name, target, slice, nil, clipmap)
				clipmap.dirty_slice_masks[axis_name][slice] = nil
				dirty_slices = dirty_slices + 1
				remaining_slices = remaining_slices - 1
				built_any_slice = true

				if not built_axes[axis_name] then
					built_axes[axis_name] = true
					dirty_axes = dirty_axes + 1
				end

				if pending.next_index > #slices then pending_slices[axis_name] = nil end

				if remaining_slices <= 0 then break end
			end
		end

		if not built_any_slice then break end
	end

	sync_dirty_slabs_from_masks(clipmap)
	local build_complete = pending_slices.x == nil and pending_slices.y == nil and pending_slices.z == nil

	if build_complete then clipmap.pending_dirty_slices = nil end

	return dirty_axes, dirty_slices, build_complete
end

function scene_voxelizer.GetClipmapBuildSliceBudget(index)
	local clipmap = scene_voxelizer.GetClipmap(index)

	if not clipmap then return scene_voxelizer.build_slices_per_frame end

	local max_active = scene_voxelizer.streaming_is_moving and
		scene_voxelizer.moving_max_active_clipmaps_per_frame or
		scene_voxelizer.settled_max_active_clipmaps_per_frame

	if max_active and max_active > 0 and clipmap.build_selected_this_frame == false then
		return 0
	end

	local build_slices = scene_voxelizer.streaming_is_moving and
		scene_voxelizer.moving_build_slices_per_frame or
		scene_voxelizer.settled_build_slices_per_frame
	local background_slices = scene_voxelizer.streaming_is_moving and
		scene_voxelizer.moving_background_build_slices_per_frame or
		scene_voxelizer.settled_background_build_slices_per_frame

	if clipmap.has_valid_data and clipmap.dirty then
		return background_slices or
			build_slices or
			scene_voxelizer.background_build_slices_per_frame or
			scene_voxelizer.build_slices_per_frame
	end

	return build_slices or scene_voxelizer.build_slices_per_frame
end

function scene_voxelizer.ConsumeClipmapClearPending(index)
	local clipmap = scene_voxelizer.GetClipmap(index)

	if not clipmap or not clipmap.pending_clear then return false end

	clipmap.pending_clear = false
	clipmap.build_target_cleared = true
	return true
end

function scene_voxelizer.ConsumeClipmapScroll(index)
	local clipmap = scene_voxelizer.GetClipmap(index)

	if not clipmap or not clipmap.pending_scroll then return nil end

	local pending_scroll = clipmap.pending_scroll
	clipmap.pending_scroll = nil
	return pending_scroll
end

function scene_voxelizer.MarkClipmapScrollReady(index)
	local clipmap = scene_voxelizer.GetClipmap(index)

	if not clipmap or not clipmap.building_into_scroll then return end

	clipmap.build_scroll_ready = true
	clipmap.build_target_cleared = true
end

function scene_voxelizer.CommitClipmapScroll(index)
	local clipmap = scene_voxelizer.GetClipmap(index)

	if not clipmap then return end

	for _, axis_name in ipairs(AXES) do
		scene_voxelizer.SwapClipmapAxisTarget(index, axis_name)
	end

	swap_target_content_versions(clipmap)
	set_scene_origin(scene_voxelizer, clipmap, clipmap.build_origin)
	clipmap.building_into_scroll = false
	clipmap.has_valid_data = true
	clipmap.build_scroll_ready = false
	clipmap.last_handoff_mode = "commit_scroll"
	clipmap.last_handoff_origin = Vec3(clipmap.origin.x, clipmap.origin.y, clipmap.origin.z)
	clipmap.last_handoff_active_version = clipmap.active_content_version or 0
	clipmap.last_handoff_build_version = clipmap.build_content_version or 0
end

function scene_voxelizer.GetClipmapWorldAABB(index)
	local clipmap = scene_voxelizer.GetClipmap(index)

	if not clipmap then return nil end

	return clipmap.world_aabb
end

function scene_voxelizer.GetClipmapWorldCenter(index)
	local clipmap = scene_voxelizer.GetClipmap(index)

	if not clipmap then return nil end

	return clipmap.origin
end

function scene_voxelizer.GetClipmapVisibleVisuals(index)
	local clipmap = scene_voxelizer.GetClipmap(index)

	if not clipmap then return {} end

	local visual = get_visual_library()

	if not visual or not visual.GetAABBVisibleVisuals then return {} end

	return visual.GetAABBVisibleVisuals(clipmap.build_world_aabb or clipmap.world_aabb)
end

function scene_voxelizer.ShouldVoxelizeMaterial(material)
	if not material then return false end

	if material.GetIgnoreZ and material:GetIgnoreZ() then return false end

	if material.GetTranslucent and material:GetTranslucent() then return false end

	return true
end

function scene_voxelizer.DrawClipmapGeometry(index, submit_entry)
	local visuals = scene_voxelizer.GetClipmapVisibleVisuals(index)
	local submitted_visuals = 0
	local submitted_entries = 0

	for _, component in ipairs(visuals) do
		local entry_count = component:DrawVoxelGeometry(scene_voxelizer, index, submit_entry)

		if entry_count and entry_count > 0 then
			submitted_visuals = submitted_visuals + 1
			submitted_entries = submitted_entries + entry_count
		end
	end

	scene_voxelizer.frame_stats.voxel_visuals = submitted_visuals
	scene_voxelizer.frame_stats.voxel_entries = submitted_entries
	return submitted_visuals, submitted_entries
end

function scene_voxelizer.GetContainingClipmapIndex(world_position)
	for index = 1, scene_voxelizer.clipmap_count or 0 do
		local clipmap = ensure_clipmap_state(scene_voxelizer, index)

		if clipmap.world_aabb:IsPointInside(world_position) then return index end
	end

	return nil
end

function scene_voxelizer.WorldToVoxel(index, world_position)
	local clipmap = scene_voxelizer.GetClipmap(index)

	if not clipmap then return nil end

	return scene_voxelizer.scene_grid:WorldToVoxel(index, world_position)
end

function scene_voxelizer.WorldToNearestVoxel(world_position)
	local clipmap_index = scene_voxelizer.GetContainingClipmapIndex(world_position)

	if not clipmap_index then return nil end

	return scene_voxelizer.WorldToVoxel(clipmap_index, world_position)
end

function scene_voxelizer.VoxelToWorld(index, voxel_position)
	local clipmap = scene_voxelizer.GetClipmap(index)

	if not clipmap then return nil end

	return scene_voxelizer.scene_grid:VoxelToWorld(index, voxel_position)
end

function scene_voxelizer.InvalidateAll(full_rebuild)
	for _, clipmap in ipairs(scene_voxelizer.clipmaps or {}) do
		clipmap.dirty = true
		clipmap.full_rebuild = full_rebuild ~= false
		clipmap.axis_full_rebuild.x = clipmap.full_rebuild
		clipmap.axis_full_rebuild.y = clipmap.full_rebuild
		clipmap.axis_full_rebuild.z = clipmap.full_rebuild
		clipmap.build_selected_this_frame = true
		clipmap.building_into_scroll = clipmap.full_rebuild and clipmap.has_valid_data == true
		mark_all_dirty_slices(clipmap)
		reset_pending_build_state(clipmap)
	end
end

function scene_voxelizer.BeginBuildFrame()
	scene_voxelizer.frame_stats.voxel_build_clipmaps = 0
	scene_voxelizer.frame_stats.voxel_build_axes = 0
	scene_voxelizer.frame_stats.voxel_build_slices = 0
	scene_voxelizer.frame_stats.voxel_scroll_inline_clipmaps = 0
	scene_voxelizer.frame_stats.voxel_scroll_submit_clipmaps = 0
	scene_voxelizer.frame_stats.voxel_scroll_submissions = 0
	scene_voxelizer.frame_stats.voxel_scroll_submit_waits = 0
end

function scene_voxelizer.AddBuildWork(clipmap_count, axis_count, slice_count)
	scene_voxelizer.frame_stats.voxel_build_clipmaps = scene_voxelizer.frame_stats.voxel_build_clipmaps + (clipmap_count or 0)
	scene_voxelizer.frame_stats.voxel_build_axes = scene_voxelizer.frame_stats.voxel_build_axes + (axis_count or 0)
	scene_voxelizer.frame_stats.voxel_build_slices = scene_voxelizer.frame_stats.voxel_build_slices + (slice_count or 0)
end

function scene_voxelizer.AddScrollSubmitWork(clipmap_count, submission_count, wait_count)
	scene_voxelizer.frame_stats.voxel_scroll_submit_clipmaps = scene_voxelizer.frame_stats.voxel_scroll_submit_clipmaps + (clipmap_count or 0)
	scene_voxelizer.frame_stats.voxel_scroll_submissions = scene_voxelizer.frame_stats.voxel_scroll_submissions + (submission_count or 0)
	scene_voxelizer.frame_stats.voxel_scroll_submit_waits = scene_voxelizer.frame_stats.voxel_scroll_submit_waits + (wait_count or 0)
end

function scene_voxelizer.AddInlineScrollWork(clipmap_count)
	scene_voxelizer.frame_stats.voxel_scroll_inline_clipmaps = scene_voxelizer.frame_stats.voxel_scroll_inline_clipmaps + (clipmap_count or 0)
end

function scene_voxelizer.Update(camera_position)
	if not scene_voxelizer.IsEnabled() then
		scene_voxelizer.frame_stats.updated_clipmaps = 0
		scene_voxelizer.frame_stats.full_rebuilds = 0
		scene_voxelizer.frame_stats.incremental_rebuilds = 0
		scene_voxelizer.frame_stats.voxel_visuals = 0
		scene_voxelizer.frame_stats.voxel_entries = 0
		scene_voxelizer.frame_stats.voxel_build_clipmaps = 0
		scene_voxelizer.frame_stats.voxel_build_axes = 0
		scene_voxelizer.frame_stats.voxel_build_slices = 0
		scene_voxelizer.frame_stats.voxel_scroll_inline_clipmaps = 0
		scene_voxelizer.frame_stats.voxel_scroll_submit_clipmaps = 0
		scene_voxelizer.frame_stats.voxel_scroll_submissions = 0
		scene_voxelizer.frame_stats.voxel_scroll_submit_waits = 0
		return false
	end

	scene_voxelizer.last_camera_position = Vec3(camera_position.x, camera_position.y, camera_position.z)
	scene_voxelizer.frame_stats.updated_clipmaps = 0
	scene_voxelizer.frame_stats.full_rebuilds = 0
	scene_voxelizer.frame_stats.incremental_rebuilds = 0
	scene_voxelizer.frame_stats.voxel_visuals = 0
	scene_voxelizer.frame_stats.voxel_entries = 0
	scene_voxelizer.frame_stats.voxel_build_clipmaps = 0
	scene_voxelizer.frame_stats.voxel_build_axes = 0
	scene_voxelizer.frame_stats.voxel_build_slices = 0
	scene_voxelizer.frame_stats.voxel_scroll_inline_clipmaps = 0
	scene_voxelizer.frame_stats.voxel_scroll_submit_clipmaps = 0
	scene_voxelizer.frame_stats.voxel_scroll_submissions = 0
	scene_voxelizer.frame_stats.voxel_scroll_submit_waits = 0
	local any_dirty = false
	local streaming_is_moving = false

	for index = 1, scene_voxelizer.clipmap_count do
		local clipmap = ensure_clipmap_state(scene_voxelizer, index)
		local snap_stride = clipmap.voxel_size * math.max(scene_voxelizer.clipmap_snap_voxel_stride or 1, 1)
		local snapped_origin = build_snapped_origin(camera_position, snap_stride)
		local target_origin = snapped_origin
		local full_rebuild_in_flight = clipmap.full_rebuild and clipmap.dirty and clipmap.has_valid_data == true
		local previous_origin = clipmap.origin
		local build_target_changed = not origins_match(clipmap.build_origin, target_origin)
		local delta_x = (target_origin.x - previous_origin.x) / clipmap.voxel_size
		local delta_y = (target_origin.y - previous_origin.y) / clipmap.voxel_size
		local delta_z = (target_origin.z - previous_origin.z) / clipmap.voxel_size
		delta_x = round_delta_to_voxels(delta_x)
		delta_y = round_delta_to_voxels(delta_y)
		delta_z = round_delta_to_voxels(delta_z)
		local origin_changed = delta_x ~= 0 or delta_y ~= 0 or delta_z ~= 0
		clipmap.previous_origin = Vec3(target_origin.x, target_origin.y, target_origin.z)

		if not clipmap.build_scroll_ready and not full_rebuild_in_flight then
			set_scene_build_origin(scene_voxelizer, clipmap, target_origin)
		end

		if
			not clipmap.has_valid_data or
			not (
				clipmap.building_into_scroll or
				origin_changed
			)
		then
			set_scene_origin(scene_voxelizer, clipmap, target_origin)
		end

		clipmap.delta.x = delta_x
		clipmap.delta.y = delta_y
		clipmap.delta.z = delta_z
		local can_scroll = clipmap.has_valid_data and
			math.abs(delta_x) < clipmap.resolution and
			math.abs(delta_y) < clipmap.resolution and
			math.abs(delta_z) < clipmap.resolution

		if clipmap.full_rebuild then
			clipmap.dirty = true
			clipmap.clear_dirty_slices = true
			clipmap.axis_full_rebuild.x = true
			clipmap.axis_full_rebuild.y = true
			clipmap.axis_full_rebuild.z = true

			if not has_any_dirty_slices(clipmap) then
				mark_all_dirty_slices(clipmap)
				reset_pending_build_state(clipmap)
			end

			if origin_changed and not full_rebuild_in_flight then
				clipmap.building_into_scroll = clipmap.has_valid_data == true
				mark_all_dirty_slices(clipmap)
			end

			if origin_changed and not full_rebuild_in_flight then
				reset_pending_build_state(clipmap)
			end

			scene_voxelizer.frame_stats.updated_clipmaps = scene_voxelizer.frame_stats.updated_clipmaps + 1
			scene_voxelizer.frame_stats.full_rebuilds = scene_voxelizer.frame_stats.full_rebuilds + 1
			any_dirty = true
		elseif origin_changed and can_scroll then
			if not clipmap.building_into_scroll then
				schedule_incremental_scroll_rebuild(scene_voxelizer, clipmap, target_origin)
			elseif not clipmap.build_scroll_ready and build_target_changed then
				schedule_incremental_scroll_rebuild(scene_voxelizer, clipmap, target_origin)
			end

			scene_voxelizer.frame_stats.updated_clipmaps = scene_voxelizer.frame_stats.updated_clipmaps + 1
			scene_voxelizer.frame_stats.incremental_rebuilds = scene_voxelizer.frame_stats.incremental_rebuilds + 1
			any_dirty = true
		elseif origin_changed then
			set_scene_origin(scene_voxelizer, clipmap, target_origin)
			clipmap.dirty = true
			clipmap.full_rebuild = true
			clipmap.clear_dirty_slices = true
			clipmap.axis_full_rebuild.x = true
			clipmap.axis_full_rebuild.y = true
			clipmap.axis_full_rebuild.z = true
			clipmap.building_into_scroll = false
			mark_all_dirty_slices(clipmap)
			reset_pending_build_state(clipmap)
			scene_voxelizer.frame_stats.full_rebuilds = scene_voxelizer.frame_stats.full_rebuilds + 1
			scene_voxelizer.frame_stats.updated_clipmaps = scene_voxelizer.frame_stats.updated_clipmaps + 1
			any_dirty = true
		elseif has_any_dirty_slices(clipmap) then
			clipmap.dirty = true
			clipmap.full_rebuild = false
			clipmap.axis_full_rebuild.x = false
			clipmap.axis_full_rebuild.y = false
			clipmap.axis_full_rebuild.z = false
			clipmap.building_into_scroll = false
			clipmap.pending_clear = false
			clipmap.pending_scroll = nil
			scene_voxelizer.frame_stats.updated_clipmaps = scene_voxelizer.frame_stats.updated_clipmaps + 1
			scene_voxelizer.frame_stats.incremental_rebuilds = scene_voxelizer.frame_stats.incremental_rebuilds + 1
			any_dirty = true
		else
			clipmap.dirty = false
			clipmap.full_rebuild = false
			clipmap.clear_dirty_slices = false
			clipmap.axis_full_rebuild.x = false
			clipmap.axis_full_rebuild.y = false
			clipmap.axis_full_rebuild.z = false
			clipmap.building_into_scroll = false
			clear_dirty_slice_masks(clipmap)
			clipmap.pending_clear = false
			clipmap.pending_scroll = nil
			clipmap.build_scroll_ready = false
		end

		if
			origin_changed or
			clipmap.building_into_scroll or
			clipmap.pending_scroll ~= nil or
			clipmap.build_scroll_ready
		then
			streaming_is_moving = true
		end
	end

	scene_voxelizer.streaming_is_moving = streaming_is_moving
	update_build_selection()
	return any_dirty
end

function scene_voxelizer.MarkClipmapClean(index)
	local clipmap = scene_voxelizer.GetClipmap(index)

	if not clipmap then return end

	clipmap.dirty = false
	clipmap.full_rebuild = false
	clipmap.clear_dirty_slices = false
	clipmap.axis_full_rebuild.x = false
	clipmap.axis_full_rebuild.y = false
	clipmap.axis_full_rebuild.z = false
	clipmap.building_into_scroll = false
	clear_dirty_slice_masks(clipmap)
	clipmap.pending_clear = false
	clipmap.build_target_cleared = false
	clipmap.pending_scroll = nil
	clipmap.build_scroll_ready = false
end

function scene_voxelizer.MarkClipmapBuilt(index, axis_count, slice_count)
	local clipmap = scene_voxelizer.GetClipmap(index)

	if not clipmap then return end

	scene_voxelizer.AddBuildWork(1, axis_count, slice_count)
	clipmap.last_handoff_rescheduled = false

	if clipmap.building_into_scroll then
		local snap_stride = clipmap.voxel_size * math.max(scene_voxelizer.clipmap_snap_voxel_stride or 1, 1)
		local latest_origin = build_snapped_origin(scene_voxelizer.last_camera_position, snap_stride)
		local build_origin = Vec3(clipmap.build_origin.x, clipmap.build_origin.y, clipmap.build_origin.z)
		complete_target_content_version(clipmap, "build")
		scene_voxelizer.CommitClipmapScroll(index)
		clipmap = scene_voxelizer.GetClipmap(index)

		if
			latest_origin.x ~= build_origin.x or
			latest_origin.y ~= build_origin.y or
			latest_origin.z ~= build_origin.z
		then
			clipmap.last_handoff_rescheduled = true
			schedule_incremental_scroll_rebuild(scene_voxelizer, clipmap, latest_origin)
			return
		end
	else
		complete_target_content_version(clipmap, "active")
		clipmap.last_handoff_mode = "complete_active"
		clipmap.last_handoff_origin = Vec3(clipmap.origin.x, clipmap.origin.y, clipmap.origin.z)
		clipmap.last_handoff_active_version = clipmap.active_content_version or 0
		clipmap.last_handoff_build_version = clipmap.build_content_version or 0
	end

	scene_voxelizer.SwapClipmapBuildResults(index)
	--set_scene_origin(scene_voxelizer, clipmap, clipmap.build_origin)
	scene_voxelizer.MarkClipmapClean(index)
end

function scene_voxelizer.GetClipmapDebugInfo(index)
	local clipmap = scene_voxelizer.GetClipmap(index)

	if not clipmap then return nil end

	local snap_stride = clipmap.voxel_size * math.max(scene_voxelizer.clipmap_snap_voxel_stride or 1, 1)
	local latest_origin = build_snapped_origin(scene_voxelizer.last_camera_position, snap_stride)
	local active_target = scene_voxelizer.GetClipmapAxisTarget(index, "x")
	local build_target = scene_voxelizer.GetClipmapScrollTarget(index, "x")
	local sampled_target = scene_voxelizer.GetClipmapLightingAxisTarget(index, "x")
	local sampled_origin = scene_voxelizer.GetClipmapLightingOrigin(index) or clipmap.origin
	local sampled_content_version = clipmap.build_scroll_ready and
		(
			clipmap.build_content_version or
			0
		)
		or
		(
			clipmap.active_content_version or
			0
		)
	local pending_counts = {}

	local function to_voxel_delta(from, to)
		return Vec3(
			(to.x - from.x) / clipmap.voxel_size,
			(to.y - from.y) / clipmap.voxel_size,
			(to.z - from.z) / clipmap.voxel_size
		)
	end

	local pending_ranges = {}

	for _, axis_name in ipairs(AXES) do
		local pending = clipmap.pending_dirty_slices and clipmap.pending_dirty_slices[axis_name] or nil
		local slices = pending and pending.slices or nil
		local next_index = pending and pending.next_index or 1

		if slices and next_index <= #slices then
			pending_ranges[axis_name] = {}

			for i = next_index, #slices do
				pending_ranges[axis_name][#pending_ranges[axis_name] + 1] = slices[i]
			end

			pending_counts[axis_name] = #slices - next_index + 1
		else
			pending_ranges[axis_name] = false
			pending_counts[axis_name] = 0
		end
	end

	return {
		index = index,
		resolution = clipmap.resolution,
		voxel_size = clipmap.voxel_size,
		world_span = clipmap.world_span,
		snap_stride = snap_stride,
		camera_position = Vec3(
			scene_voxelizer.last_camera_position.x,
			scene_voxelizer.last_camera_position.y,
			scene_voxelizer.last_camera_position.z
		),
		latest_origin = latest_origin,
		origin = Vec3(clipmap.origin.x, clipmap.origin.y, clipmap.origin.z),
		build_origin = Vec3(clipmap.build_origin.x, clipmap.build_origin.y, clipmap.build_origin.z),
		sampled_origin = Vec3(sampled_origin.x, sampled_origin.y, sampled_origin.z),
		sampled_source = clipmap.build_scroll_ready and "build" or "active",
		active_target_id = get_target_debug_id(active_target),
		build_target_id = get_target_debug_id(build_target),
		sampled_target_id = get_target_debug_id(sampled_target),
		active_content_version = clipmap.active_content_version or 0,
		build_content_version = clipmap.build_content_version or 0,
		sampled_content_version = sampled_content_version,
		last_handoff_mode = clipmap.last_handoff_mode,
		last_handoff_origin = Vec3(clipmap.last_handoff_origin.x, clipmap.last_handoff_origin.y, clipmap.last_handoff_origin.z),
		last_handoff_active_version = clipmap.last_handoff_active_version or 0,
		last_handoff_build_version = clipmap.last_handoff_build_version or 0,
		last_handoff_rescheduled = clipmap.last_handoff_rescheduled == true,
		active_to_latest_voxels = to_voxel_delta(clipmap.origin, latest_origin),
		build_to_latest_voxels = to_voxel_delta(clipmap.build_origin, latest_origin),
		sampled_to_latest_voxels = to_voxel_delta(sampled_origin, latest_origin),
		delta = Vec3(clipmap.delta.x, clipmap.delta.y, clipmap.delta.z),
		dirty = clipmap.dirty == true,
		full_rebuild = clipmap.full_rebuild == true,
		clear_dirty_slices = clipmap.clear_dirty_slices == true,
		building_into_scroll = clipmap.building_into_scroll == true,
		build_scroll_ready = clipmap.build_scroll_ready == true,
		has_valid_data = clipmap.has_valid_data == true,
		pending_clear = clipmap.pending_clear == true,
		pending_scroll = clipmap.pending_scroll ~= nil,
		build_selected_this_frame = clipmap.build_selected_this_frame == true,
		streaming_is_moving = scene_voxelizer.streaming_is_moving == true,
		build_slice_budget = scene_voxelizer.GetClipmapBuildSliceBudget(index),
		dirty_slabs = {
			x = clipmap.dirty_slabs.x or 0,
			y = clipmap.dirty_slabs.y or 0,
			z = clipmap.dirty_slabs.z or 0,
		},
		pending_counts = pending_counts,
		pending_ranges = pending_ranges,
	}
end

function scene_voxelizer.GetDebugState()
	return {
		enabled = scene_voxelizer.IsEnabled(),
		clipmap_count = scene_voxelizer.clipmap_count or 0,
		base_resolution = scene_voxelizer.base_resolution,
		base_voxel_size = scene_voxelizer.base_voxel_size,
		last_camera_position = scene_voxelizer.last_camera_position,
		frame_stats = scene_voxelizer.frame_stats,
		containing_clipmap = scene_voxelizer.GetContainingClipmapIndex(scene_voxelizer.last_camera_position),
		clipmaps = scene_voxelizer.GetClipmaps(),
	}
end

function scene_voxelizer.Shutdown()
	if scene_voxelizer.scene_grid and scene_voxelizer.scene_grid.Shutdown then
		scene_voxelizer.scene_grid:Shutdown()
	end
end

return scene_voxelizer.ResetState()
