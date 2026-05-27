local Vec3 = import("goluwa/structs/vec3.lua")
local AABB = import("goluwa/structs/aabb.lua")
local render = import("goluwa/render/render.lua")
local Texture = import("goluwa/render/texture.lua")
local scene_voxelizer = library()
scene_voxelizer.DEFAULT_CLIPMAP_RESOLUTION = 128
scene_voxelizer.DEFAULT_CLIPMAP_COUNT = 3
scene_voxelizer.DEFAULT_BASE_VOXEL_SIZE = 0.5
scene_voxelizer.DEFAULT_CLIPMAP_SNAP_VOXEL_STRIDE = 1
scene_voxelizer.DEFAULT_BUILD_SLICES_PER_FRAME = 12
scene_voxelizer.DEFAULT_BACKGROUND_BUILD_SLICES_PER_FRAME = 24

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

local function ensure_clipmap_state(self, index)
	local clipmap = self.clipmaps[index]

	if clipmap then return clipmap end

	local resolution = get_clipmap_resolution(self, index)
	local voxel_size = get_clipmap_voxel_size(self, index)
	local world_span = resolution * voxel_size
	clipmap = {
		index = index,
		resolution = resolution,
		voxel_size = voxel_size,
		world_span = world_span,
		origin = Vec3(0, 0, 0),
		build_origin = Vec3(0, 0, 0),
		world_aabb = AABB(
			-world_span * 0.5,
			-world_span * 0.5,
			-world_span * 0.5,
			world_span * 0.5,
			world_span * 0.5,
			world_span * 0.5
		),
		build_world_aabb = AABB(
			-world_span * 0.5,
			-world_span * 0.5,
			-world_span * 0.5,
			world_span * 0.5,
			world_span * 0.5,
			world_span * 0.5
		),
		previous_origin = nil,
		delta = Vec3(0, 0, 0),
		dirty = true,
		full_rebuild = true,
		axis_full_rebuild = {x = true, y = true, z = true},
		building_into_scroll = false,
		has_valid_data = false,
		dirty_slabs = {x = 0, y = 0, z = 0},
		pending_dirty_ranges = nil,
		pending_clear = true,
		pending_scroll = nil,
		resources = nil,
	}
	self.clipmaps[index] = clipmap
	return clipmap
end

local function reset_pending_build_state(clipmap)
	clipmap.pending_dirty_ranges = nil
	clipmap.pending_clear = clipmap.dirty == true or clipmap.full_rebuild == true
	clipmap.pending_scroll = nil
end

local function destroy_layer_views(layer_views)
	if not layer_views then return end

	for _, view in pairs(layer_views) do
		if view and view.Remove then view:Remove() end
	end
end

local function destroy_volume_target(target)
	if not target then return end

	if target.sample_view and target.sample_view.Remove then
		target.sample_view:Remove()
	end

	destroy_layer_views(target.layer_views)

	if target.texture and target.texture.Remove then target.texture:Remove() end
end

local function destroy_clipmap_resources(clipmap)
	if not clipmap or not clipmap.resources then return end

	for _, target_group in pairs{clipmap.resources.axis_targets, clipmap.resources.scroll_targets} do
		if target_group then
			for _, target in pairs(target_group) do
				destroy_volume_target(target)
			end
		end
	end

	clipmap.resources = nil
end

local function create_volume_target(clipmap, axis_name, label_suffix)
	local resolution = clipmap.resolution
	local texture = Texture.New{
		width = resolution,
		height = resolution,
		format = "r16g16b16a16_sfloat",
		mip_map_levels = 1,
		image = {
			array_layers = resolution,
			usage = {"color_attachment", "sampled", "transfer_src", "transfer_dst"},
		},
		view = {
			view_type = "2d_array",
			layer_count = resolution,
		},
		sampler = {
			min_filter = "nearest",
			mag_filter = "nearest",
			wrap_s = "clamp_to_edge",
			wrap_t = "clamp_to_edge",
			wrap_r = "clamp_to_edge",
		},
	}
	local target_name = "render3d voxel clipmap " .. tostring(clipmap.index) .. " axis " .. axis_name

	if label_suffix then target_name = target_name .. " " .. label_suffix end

	texture:SetDebugName(target_name)
	local target = {
		axis = axis_name,
		texture = texture,
		sample_view = texture:GetImage():CreateView{
			view_type = "2d_array",
			base_array_layer = 0,
			layer_count = resolution,
			base_mip_level = 0,
			level_count = 1,
		},
		layer_views = {},
		sampler = render.CreateSampler(texture:GetSamplerConfig()),
	}

	for slice = 0, resolution - 1 do
		target.layer_views[slice] = texture:GetImage():CreateView{
			view_type = "2d",
			base_array_layer = slice,
			layer_count = 1,
			base_mip_level = 0,
			level_count = 1,
		}

		if target.layer_views[slice].SetDebugName then
			target.layer_views[slice]:SetDebugName(target_name .. " slice " .. tostring(slice))
		end
	end

	return target
end

local function ensure_clipmap_resources(clipmap)
	local resources = clipmap.resources

	if resources and resources.resolution == clipmap.resolution then
		return resources
	end

	destroy_clipmap_resources(clipmap)
	resources = {
		resolution = clipmap.resolution,
		axis_targets = {
			x = create_volume_target(clipmap, "x"),
			y = create_volume_target(clipmap, "y"),
			z = create_volume_target(clipmap, "z"),
		},
		scroll_targets = {
			x = create_volume_target(clipmap, "x", "scroll"),
			y = create_volume_target(clipmap, "y", "scroll"),
			z = create_volume_target(clipmap, "z", "scroll"),
		},
	}
	clipmap.resources = resources
	return resources
end

local function build_axis_scroll_state(delta_x, delta_y, delta_z)
	return {
		x = {
			layer_delta = delta_x,
			x_delta = -delta_z,
			y_delta = -delta_y,
			full_rebuild = delta_y ~= 0 or delta_z ~= 0,
		},
		y = {
			layer_delta = delta_y,
			x_delta = -delta_x,
			y_delta = delta_z,
			full_rebuild = delta_x ~= 0 or delta_z ~= 0,
		},
		z = {
			layer_delta = delta_z,
			x_delta = -delta_x,
			y_delta = -delta_y,
			full_rebuild = delta_x ~= 0 or delta_y ~= 0,
		},
	}
end

local function get_dirty_slice_span(clipmap, axis_name)
	if
		clipmap.full_rebuild or
		(
			clipmap.axis_full_rebuild and
			clipmap.axis_full_rebuild[axis_name]
		)
	then
		return 0, clipmap.resolution - 1, clipmap.resolution, 1
	end

	local delta = clipmap.delta[axis_name]

	if not delta or delta == 0 then return nil end

	local dirty_count = math.min(math.abs(delta), clipmap.resolution)

	if dirty_count <= 0 then return nil end

	if delta > 0 then
		return clipmap.resolution - dirty_count, clipmap.resolution - 1, dirty_count, 1
	end

	return 0, dirty_count - 1, dirty_count, -1
end

function scene_voxelizer.ResetState(config)
	config = config or {}

	if scene_voxelizer.clipmaps then
		for _, clipmap in ipairs(scene_voxelizer.clipmaps) do
			destroy_clipmap_resources(clipmap)
		end
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
	scene_voxelizer.clipmap_resolutions = config.clipmap_resolutions
	scene_voxelizer.clipmap_voxel_sizes = config.clipmap_voxel_sizes
	scene_voxelizer.clipmaps = {}
	scene_voxelizer.debug_enabled = config.debug_enabled == true
	scene_voxelizer.last_camera_position = Vec3(0, 0, 0)
	scene_voxelizer.frame_stats = {
		updated_clipmaps = 0,
		full_rebuilds = 0,
		incremental_rebuilds = 0,
		voxel_visuals = 0,
		voxel_entries = 0,
		voxel_build_clipmaps = 0,
		voxel_build_axes = 0,
		voxel_build_slices = 0,
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

	return ensure_clipmap_resources(clipmap)
end

function scene_voxelizer.GetClipmapAxisTarget(index, axis_name)
	local resources = scene_voxelizer.EnsureClipmapResources(index)
	return resources and resources.axis_targets and resources.axis_targets[axis_name] or nil
end

function scene_voxelizer.GetClipmapBuildAxisTarget(index, axis_name)
	local clipmap = scene_voxelizer.GetClipmap(index)
	local resources = scene_voxelizer.EnsureClipmapResources(index)

	if not resources then return nil end

	if clipmap and clipmap.building_into_scroll then
		return resources.scroll_targets and resources.scroll_targets[axis_name] or nil
	end

	return resources.axis_targets and resources.axis_targets[axis_name] or nil
end

function scene_voxelizer.GetClipmapScrollTarget(index, axis_name)
	local resources = scene_voxelizer.EnsureClipmapResources(index)
	return resources and
		resources.scroll_targets and
		resources.scroll_targets[axis_name] or
		nil
end

function scene_voxelizer.SwapClipmapAxisTarget(index, axis_name)
	local resources = scene_voxelizer.EnsureClipmapResources(index)

	if not resources or not resources.axis_targets or not resources.scroll_targets then
		return
	end

	resources.axis_targets[axis_name], resources.scroll_targets[axis_name] = resources.scroll_targets[axis_name], resources.axis_targets[axis_name]
end

function scene_voxelizer.SwapClipmapBuildResults(index)
	local clipmap = scene_voxelizer.GetClipmap(index)

	if not clipmap or not clipmap.building_into_scroll then
		if clipmap then clipmap.has_valid_data = true end

		return
	end

	for _, axis_name in ipairs({"x", "y", "z"}) do
		scene_voxelizer.SwapClipmapAxisTarget(index, axis_name)
	end

	clipmap.building_into_scroll = false
	clipmap.has_valid_data = true
end

function scene_voxelizer.GetClipmapDirtySliceRange(index, axis_name)
	local clipmap = scene_voxelizer.GetClipmap(index)

	if not clipmap then return nil end

	local start_slice, end_slice, count, direction = get_dirty_slice_span(clipmap, axis_name)

	if not start_slice then return nil end

	return {
		start_slice = start_slice,
		end_slice = end_slice,
		count = count,
		direction = direction,
	}
end

function scene_voxelizer.ForEachDirtySlice(index, axis_name, callback)
	local dirty_range = scene_voxelizer.GetClipmapDirtySliceRange(index, axis_name)

	if not dirty_range then return 0 end

	for slice = dirty_range.start_slice, dirty_range.end_slice do
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

	local resources = scene_voxelizer.EnsureClipmapResources(index)
	local pending_ranges = clipmap.pending_dirty_ranges

	if not pending_ranges then
		pending_ranges = {}

		for _, axis_name in ipairs({"x", "y", "z"}) do
			local dirty_range = scene_voxelizer.GetClipmapDirtySliceRange(index, axis_name)

			if dirty_range then
				pending_ranges[axis_name] = {
					start_slice = dirty_range.start_slice,
					end_slice = dirty_range.end_slice,
					direction = dirty_range.direction,
					next_slice = dirty_range.start_slice,
				}
			end
		end

		clipmap.pending_dirty_ranges = pending_ranges
	end

	local dirty_axes = 0
	local dirty_slices = 0
	local remaining_slices = math.max(math.floor(slice_budget or scene_voxelizer.build_slices_per_frame or 1), 1)

	for _, axis_name in ipairs({"x", "y", "z"}) do
		local target = scene_voxelizer.GetClipmapBuildAxisTarget(index, axis_name)
		local dirty_range = pending_ranges[axis_name]

		if target and dirty_range then
			local axis_slices = 0

			while remaining_slices > 0 do
				local slice = dirty_range.next_slice

				if dirty_range.direction > 0 and slice > dirty_range.end_slice then break end

				if dirty_range.direction < 0 and slice < dirty_range.end_slice then break end

				callback(axis_name, target, slice, dirty_range, clipmap)
				dirty_slices = dirty_slices + 1
				axis_slices = axis_slices + 1
				remaining_slices = remaining_slices - 1
				dirty_range.next_slice = slice + dirty_range.direction
			end

			if axis_slices > 0 then dirty_axes = dirty_axes + 1 end

			local next_slice = dirty_range.next_slice

			if
				(
					dirty_range.direction > 0 and
					next_slice > dirty_range.end_slice
				)
				or
				(
					dirty_range.direction < 0 and
					next_slice < dirty_range.end_slice
				)
			then
				pending_ranges[axis_name] = nil
			end

			if remaining_slices <= 0 then break end
		end
	end

	local build_complete = pending_ranges.x == nil and pending_ranges.y == nil and pending_ranges.z == nil

	if build_complete then clipmap.pending_dirty_ranges = nil end

	return dirty_axes, dirty_slices, build_complete
end

function scene_voxelizer.GetClipmapBuildSliceBudget(index)
	local clipmap = scene_voxelizer.GetClipmap(index)

	if not clipmap then return scene_voxelizer.build_slices_per_frame end

	if clipmap.building_into_scroll and clipmap.has_valid_data then
		return scene_voxelizer.background_build_slices_per_frame or
			scene_voxelizer.build_slices_per_frame
	end

	return scene_voxelizer.build_slices_per_frame
end

function scene_voxelizer.ConsumeClipmapClearPending(index)
	local clipmap = scene_voxelizer.GetClipmap(index)

	if not clipmap or not clipmap.pending_clear then return false end

	clipmap.pending_clear = false
	return true
end

function scene_voxelizer.ConsumeClipmapScroll(index)
	local clipmap = scene_voxelizer.GetClipmap(index)

	if not clipmap or not clipmap.pending_scroll then return nil end

	local pending_scroll = clipmap.pending_scroll
	clipmap.pending_scroll = nil
	return pending_scroll
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

	local voxel_xf, voxel_yf, voxel_zf = get_centered_voxel_coordinates(clipmap, world_position)
	local voxel_x = math.floor(voxel_xf)
	local voxel_y = math.floor(voxel_yf)
	local voxel_z = math.floor(voxel_zf)
	local inside = voxel_x >= 0 and
		voxel_x < clipmap.resolution and
		voxel_y >= 0 and
		voxel_y < clipmap.resolution and
		voxel_z >= 0 and
		voxel_z < clipmap.resolution
	return {
		clipmap_index = index,
		inside = inside,
		voxel = Vec3(voxel_x, voxel_y, voxel_z),
		fractional = Vec3(voxel_xf, voxel_yf, voxel_zf),
		normalized = Vec3(
			voxel_xf / clipmap.resolution,
			voxel_yf / clipmap.resolution,
			voxel_zf / clipmap.resolution
		),
		voxel_size = clipmap.voxel_size,
		resolution = clipmap.resolution,
	}
end

function scene_voxelizer.WorldToNearestVoxel(world_position)
	local clipmap_index = scene_voxelizer.GetContainingClipmapIndex(world_position)

	if not clipmap_index then return nil end

	return scene_voxelizer.WorldToVoxel(clipmap_index, world_position)
end

function scene_voxelizer.VoxelToWorld(index, voxel_position)
	local clipmap = scene_voxelizer.GetClipmap(index)

	if not clipmap then return nil end

	local half_resolution = get_half_resolution(clipmap)
	local voxel_size = clipmap.voxel_size
	return Vec3(
		clipmap.origin.x + ((voxel_position.x + 0.5) - half_resolution) * voxel_size,
		clipmap.origin.y + ((voxel_position.y + 0.5) - half_resolution) * voxel_size,
		clipmap.origin.z + ((voxel_position.z + 0.5) - half_resolution) * voxel_size
	)
end

function scene_voxelizer.InvalidateAll(full_rebuild)
	for _, clipmap in ipairs(scene_voxelizer.clipmaps or {}) do
		clipmap.dirty = true
		clipmap.full_rebuild = full_rebuild ~= false
		clipmap.axis_full_rebuild.x = clipmap.full_rebuild
		clipmap.axis_full_rebuild.y = clipmap.full_rebuild
		clipmap.axis_full_rebuild.z = clipmap.full_rebuild
		clipmap.building_into_scroll = clipmap.full_rebuild and clipmap.has_valid_data == true
		clipmap.dirty_slabs.x = clipmap.resolution
		clipmap.dirty_slabs.y = clipmap.resolution
		clipmap.dirty_slabs.z = clipmap.resolution
		reset_pending_build_state(clipmap)
	end
end

function scene_voxelizer.BeginBuildFrame()
	scene_voxelizer.frame_stats.voxel_build_clipmaps = 0
	scene_voxelizer.frame_stats.voxel_build_axes = 0
	scene_voxelizer.frame_stats.voxel_build_slices = 0
end

function scene_voxelizer.AddBuildWork(clipmap_count, axis_count, slice_count)
	scene_voxelizer.frame_stats.voxel_build_clipmaps = scene_voxelizer.frame_stats.voxel_build_clipmaps + (clipmap_count or 0)
	scene_voxelizer.frame_stats.voxel_build_axes = scene_voxelizer.frame_stats.voxel_build_axes + (axis_count or 0)
	scene_voxelizer.frame_stats.voxel_build_slices = scene_voxelizer.frame_stats.voxel_build_slices + (slice_count or 0)
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
	local any_dirty = false

	for index = 1, scene_voxelizer.clipmap_count do
		local clipmap = ensure_clipmap_state(scene_voxelizer, index)
		local snap_stride = clipmap.voxel_size * math.max(scene_voxelizer.clipmap_snap_voxel_stride or 1, 1)
		local snapped_origin = build_snapped_origin(camera_position, snap_stride)
		local building_in_background = clipmap.dirty and clipmap.building_into_scroll == true
		local target_origin = snapped_origin
		local previous_origin = building_in_background and clipmap.build_origin or clipmap.origin
		local delta_x = (target_origin.x - previous_origin.x) / clipmap.voxel_size
		local delta_y = (target_origin.y - previous_origin.y) / clipmap.voxel_size
		local delta_z = (target_origin.z - previous_origin.z) / clipmap.voxel_size
		delta_x = math.floor(delta_x + (delta_x >= 0 and 0.5 or -0.5))
		delta_y = math.floor(delta_y + (delta_y >= 0 and 0.5 or -0.5))
		delta_z = math.floor(delta_z + (delta_z >= 0 and 0.5 or -0.5))
		clipmap.previous_origin = Vec3(target_origin.x, target_origin.y, target_origin.z)
		clipmap.build_origin = Vec3(target_origin.x, target_origin.y, target_origin.z)
		clipmap.build_world_aabb = build_clipmap_world_aabb(clipmap, target_origin)
		local origin_changed = delta_x ~= 0 or delta_y ~= 0 or delta_z ~= 0

		if
			not clipmap.has_valid_data or
			not (
				clipmap.building_into_scroll or
				origin_changed
			)
		then
			clipmap.origin = target_origin
			clipmap.world_aabb = clipmap.build_world_aabb
		end

		clipmap.delta.x = delta_x
		clipmap.delta.y = delta_y
		clipmap.delta.z = delta_z

		if clipmap.full_rebuild then
			clipmap.dirty = true
			clipmap.axis_full_rebuild.x = true
			clipmap.axis_full_rebuild.y = true
			clipmap.axis_full_rebuild.z = true

			if origin_changed then
				clipmap.building_into_scroll = clipmap.has_valid_data == true
			end

			clipmap.dirty_slabs.x = clipmap.resolution
			clipmap.dirty_slabs.y = clipmap.resolution
			clipmap.dirty_slabs.z = clipmap.resolution

			if origin_changed then reset_pending_build_state(clipmap) end

			scene_voxelizer.frame_stats.updated_clipmaps = scene_voxelizer.frame_stats.updated_clipmaps + 1
			scene_voxelizer.frame_stats.full_rebuilds = scene_voxelizer.frame_stats.full_rebuilds + 1
			any_dirty = true
		elseif origin_changed then
			clipmap.dirty = true
			clipmap.full_rebuild = true
			clipmap.axis_full_rebuild.x = true
			clipmap.axis_full_rebuild.y = true
			clipmap.axis_full_rebuild.z = true
			clipmap.building_into_scroll = clipmap.has_valid_data == true
			clipmap.dirty_slabs.x = clipmap.resolution
			clipmap.dirty_slabs.y = clipmap.resolution
			clipmap.dirty_slabs.z = clipmap.resolution
			reset_pending_build_state(clipmap)
			scene_voxelizer.frame_stats.full_rebuilds = scene_voxelizer.frame_stats.full_rebuilds + 1
			scene_voxelizer.frame_stats.updated_clipmaps = scene_voxelizer.frame_stats.updated_clipmaps + 1
			any_dirty = true
		else
			clipmap.dirty = false
			clipmap.full_rebuild = false
			clipmap.axis_full_rebuild.x = false
			clipmap.axis_full_rebuild.y = false
			clipmap.axis_full_rebuild.z = false
			clipmap.building_into_scroll = false
			clipmap.dirty_slabs.x = 0
			clipmap.dirty_slabs.y = 0
			clipmap.dirty_slabs.z = 0
			clipmap.pending_dirty_ranges = nil
			clipmap.pending_clear = false
			clipmap.pending_scroll = nil
		end
	end

	return any_dirty
end

function scene_voxelizer.MarkClipmapClean(index)
	local clipmap = scene_voxelizer.GetClipmap(index)

	if not clipmap then return end

	clipmap.dirty = false
	clipmap.full_rebuild = false
	clipmap.axis_full_rebuild.x = false
	clipmap.axis_full_rebuild.y = false
	clipmap.axis_full_rebuild.z = false
	clipmap.building_into_scroll = false
	clipmap.dirty_slabs.x = 0
	clipmap.dirty_slabs.y = 0
	clipmap.dirty_slabs.z = 0
	clipmap.pending_dirty_ranges = nil
	clipmap.pending_clear = false
	clipmap.pending_scroll = nil
end

function scene_voxelizer.MarkClipmapBuilt(index, axis_count, slice_count)
	local clipmap = scene_voxelizer.GetClipmap(index)

	if not clipmap then return end

	scene_voxelizer.AddBuildWork(1, axis_count, slice_count)

	if clipmap.building_into_scroll then
		local snap_stride = clipmap.voxel_size * math.max(scene_voxelizer.clipmap_snap_voxel_stride or 1, 1)
		local latest_origin = build_snapped_origin(scene_voxelizer.last_camera_position, snap_stride)

		if
			latest_origin.x ~= clipmap.build_origin.x or
			latest_origin.y ~= clipmap.build_origin.y or
			latest_origin.z ~= clipmap.build_origin.z
		then
			clipmap.build_origin = latest_origin
			clipmap.build_world_aabb = build_clipmap_world_aabb(clipmap, clipmap.build_origin)
			clipmap.dirty = true
			clipmap.full_rebuild = true
			clipmap.axis_full_rebuild.x = true
			clipmap.axis_full_rebuild.y = true
			clipmap.axis_full_rebuild.z = true
			clipmap.building_into_scroll = clipmap.has_valid_data == true
			clipmap.dirty_slabs.x = clipmap.resolution
			clipmap.dirty_slabs.y = clipmap.resolution
			clipmap.dirty_slabs.z = clipmap.resolution
			reset_pending_build_state(clipmap)
			return
		end
	end

	scene_voxelizer.SwapClipmapBuildResults(index)
	clipmap.origin = Vec3(clipmap.build_origin.x, clipmap.build_origin.y, clipmap.build_origin.z)
	clipmap.world_aabb = build_clipmap_world_aabb(clipmap, clipmap.origin)
	scene_voxelizer.MarkClipmapClean(index)
end

function scene_voxelizer.GetClipmapDebugInfo(index)
	local clipmap = scene_voxelizer.GetClipmap(index)

	if not clipmap then return nil end

	local snap_stride = clipmap.voxel_size * math.max(scene_voxelizer.clipmap_snap_voxel_stride or 1, 1)
	local latest_origin = build_snapped_origin(scene_voxelizer.last_camera_position, snap_stride)
	local function to_voxel_delta(from, to)
		return Vec3(
			(to.x - from.x) / clipmap.voxel_size,
			(to.y - from.y) / clipmap.voxel_size,
			(to.z - from.z) / clipmap.voxel_size
		)
	end

	local pending_ranges = {}

	for _, axis_name in ipairs({"x", "y", "z"}) do
		local range = clipmap.pending_dirty_ranges and clipmap.pending_dirty_ranges[axis_name] or nil

		if range then
			pending_ranges[axis_name] = {
				start_slice = range.start_slice,
				end_slice = range.end_slice,
				next_slice = range.next_slice,
				direction = range.direction,
			}
		else
			pending_ranges[axis_name] = false
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
		active_to_latest_voxels = to_voxel_delta(clipmap.origin, latest_origin),
		build_to_latest_voxels = to_voxel_delta(clipmap.build_origin, latest_origin),
		delta = Vec3(clipmap.delta.x, clipmap.delta.y, clipmap.delta.z),
		dirty = clipmap.dirty == true,
		full_rebuild = clipmap.full_rebuild == true,
		building_into_scroll = clipmap.building_into_scroll == true,
		has_valid_data = clipmap.has_valid_data == true,
		pending_clear = clipmap.pending_clear == true,
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
	for _, clipmap in ipairs(scene_voxelizer.clipmaps or {}) do
		destroy_clipmap_resources(clipmap)
	end
end

return scene_voxelizer.ResetState()
