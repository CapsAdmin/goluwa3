local render = import("goluwa/render/render.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
local Fence = import("goluwa/render/vulkan/internal/fence.lua")
local orientation = import("goluwa/render3d/orientation.lua")
local model_pipeline = import("goluwa/render3d/model_pipeline.lua")
local Visual = import("goluwa/entities/components/visual.lua")
local AABB = import("goluwa/structs/aabb.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local Quat = import("goluwa/structs/quat.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local AXIS_ROTATIONS = {
	x = Quat():SetAngles(Deg3(0, -90 + 180, 0)),
	y = Quat():SetAngles(Deg3(90, 0 + 180, 0)),
	z = Quat():SetAngles(Deg3(0, 0 + 180, 0)),
}
local current_build_state = {
	clipmap_index = 0,
	axis_index = 0,
	current_slice = 0,
	resolution = 1,
	voxel_size = 1,
	world_span = 1,
	clipmap_origin = Vec3(0, 0, 0),
	view_matrix = Matrix44(),
	projection_matrix = Matrix44(),
	projection_view_world = Matrix44(),
}
local current_slice_draw_state = {
	self = nil,
	cmd = nil,
	voxelizer = nil,
	clipmap_index = 0,
	draw_list = nil,
	slice_buckets = nil,
	axis_transitioned = nil,
}
local voxel_draw_sort_ids = setmetatable({}, {__mode = "k"})
local voxel_draw_scalar_sort_ids = {}
local next_voxel_draw_sort_id = 0

local function get_voxel_draw_sort_id(value)
	if value == nil then return 0 end

	local value_type = type(value)

	if value_type == "table" or value_type == "userdata" or value_type == "function" then
		local sort_id = voxel_draw_sort_ids[value]

		if sort_id then return sort_id end

		next_voxel_draw_sort_id = next_voxel_draw_sort_id + 1
		sort_id = next_voxel_draw_sort_id
		voxel_draw_sort_ids[value] = sort_id
		return sort_id
	end

	local scalar_key = value_type .. ":" .. tostring(value)
	local sort_id = voxel_draw_scalar_sort_ids[scalar_key]

	if sort_id then return sort_id end

	next_voxel_draw_sort_id = next_voxel_draw_sort_id + 1
	sort_id = next_voxel_draw_sort_id
	voxel_draw_scalar_sort_ids[scalar_key] = sort_id
	return sort_id
end

local function compare_voxel_draw_entries(a, b)
	if a.material_sort_id ~= b.material_sort_id then
		return a.material_sort_id < b.material_sort_id
	end

	if a.polygon_sort_id ~= b.polygon_sort_id then
		return a.polygon_sort_id < b.polygon_sort_id
	end

	return false
end

local function create_voxel_slice_buckets(draw_list, clipmap)
	local slice_buckets = {
		x = {},
		y = {},
		z = {},
	}

	for _, entry in ipairs(draw_list or {}) do
		for _, axis_name in ipairs({"x", "y", "z"}) do
			local slice_range = entry.slice_ranges and entry.slice_ranges[axis_name] or nil
			local dirty_mask = clipmap and
				clipmap.dirty_slice_masks and
				clipmap.dirty_slice_masks[axis_name] or
				nil

			if slice_range and dirty_mask then
				local axis_buckets = slice_buckets[axis_name]

				for slice = slice_range.start_slice, slice_range.end_slice do
					if dirty_mask[slice] then
						local bucket = axis_buckets[slice]

						if not bucket then
							bucket = {}
							axis_buckets[slice] = bucket
						end

						bucket[#bucket + 1] = entry
					end
				end
			end
		end
	end

	return slice_buckets
end

local function get_axis_index(axis_name)
	if axis_name == "x" then return 0 end

	if axis_name == "y" then return 1 end

	return 2
end

local function transition_axis_target(cmd, target, new_layout, src_stage, dst_stage, src_access, dst_access)
	render.TransitionResourceTo(
		target.texture,
		new_layout,
		{
			cmd = cmd,
			srcStage = src_stage,
			srcAccess = src_access,
			dstStage = dst_stage,
			dstAccess = dst_access,
			base_array_layer = 0,
			layer_count = target.texture:GetHeight(),
			base_mip_level = 0,
			level_count = 1,
		}
	)
end

local function transition_axis_target_for_compute(cmd, target, write)
	render.TransitionResourceToComputeStorage(
		target.texture,
		{
			cmd = cmd,
			dstAccess = write and "shader_write" or "shader_read",
			base_array_layer = 0,
			layer_count = target.texture:GetHeight(),
			base_mip_level = 0,
			level_count = 1,
		}
	)
end

local function transition_axis_target_from_compute(cmd, target)
	render.TransitionResourceFrom(
		target.texture,
		"shader_read_only_optimal",
		{
			cmd = cmd,
			srcStage = "compute",
			srcAccess = "shader_write",
			dstStage = "fragment_shader",
			dstAccess = "shader_read",
			base_array_layer = 0,
			layer_count = target.texture:GetHeight(),
			base_mip_level = 0,
			level_count = 1,
		}
	)
end

local shared_scroll_compute_pipeline = nil
local voxel_scroll_submit_fence = nil

local function get_voxel_scroll_submit_fence()
	if voxel_scroll_submit_fence and voxel_scroll_submit_fence:IsValid() then
		return voxel_scroll_submit_fence
	end

	voxel_scroll_submit_fence = Fence.New(render.GetDevice())
	return voxel_scroll_submit_fence
end

local function submit_voxel_scroll_command_buffer(voxelizer, cmd)
	local fence = get_voxel_scroll_submit_fence()
	local queue = render.GetQueue()
	local wait_count = 0

	if queue:HasPendingSubmission(fence) then
		fence:Wait(true)
		queue:RetireFence(fence)
		wait_count = 1
	end

	render.Submit(cmd, fence)

	if voxelizer and voxelizer.AddScrollSubmitWork then
		voxelizer.AddScrollSubmitWork(1, 1, wait_count)
	end
end

local function get_scroll_compute_pipeline()
	if shared_scroll_compute_pipeline then return shared_scroll_compute_pipeline end

	shared_scroll_compute_pipeline = EasyPipeline.Compute{
		DescriptorSetCount = 32,
		LocalSize = {x = 4, y = 4, z = 4},
		descriptor_sets = {
			{
				type = "storage_image",
				binding_index = 0,
				stageFlags = "compute",
				set_index = 0,
			},
			{
				type = "storage_image",
				binding_index = 1,
				stageFlags = "compute",
				set_index = 0,
			},
		},
		block = {
			{"src_x", "int"},
			{"src_y", "int"},
			{"src_z", "int"},
			{"dst_x", "int"},
			{"dst_y", "int"},
			{"dst_z", "int"},
			{"copy_width", "int"},
			{"copy_height", "int"},
			{"copy_depth", "int"},
		},
		write = function(self, block)
			local copy = self.current_scroll_copy
			block.src_x = copy and copy.src_x or 0
			block.src_y = copy and copy.src_y or 0
			block.src_z = copy and copy.src_base_array_layer or 0
			block.dst_x = copy and copy.dst_x or 0
			block.dst_y = copy and copy.dst_y or 0
			block.dst_z = copy and copy.dst_base_array_layer or 0
			block.copy_width = copy and copy.width or 0
			block.copy_height = copy and copy.height or 0
			block.copy_depth = copy and copy.layer_count or 0
			return block
		end,
		shader = [[
			layout(set = 0, binding = 0, rgba16f) uniform readonly image2DArray src_volume;
			layout(set = 0, binding = 1, rgba16f) uniform writeonly image2DArray dst_volume;

			bool is_inside_copy(ivec3 dst_pos) {
				return
					dst_pos.x >= compute.dst_x &&
					dst_pos.y >= compute.dst_y &&
					dst_pos.z >= compute.dst_z &&
					dst_pos.x < compute.dst_x + compute.copy_width &&
					dst_pos.y < compute.dst_y + compute.copy_height &&
					dst_pos.z < compute.dst_z + compute.copy_depth;
			}

			void main() {
				ivec3 pos = ivec3(gl_GlobalInvocationID.xyz);
				ivec3 size = imageSize(dst_volume);

				if (any(greaterThanEqual(pos, size))) return;

				vec4 value = vec4(0.0);

				if (is_inside_copy(pos)) {
					ivec3 src_pos = ivec3(
						pos.x - compute.dst_x + compute.src_x,
						pos.y - compute.dst_y + compute.src_y,
						pos.z - compute.dst_z + compute.src_z
					);
					value = imageLoad(src_volume, src_pos);
				}

				imageStore(dst_volume, pos, value);
			}
		]],
	}
	return shared_scroll_compute_pipeline
end

local function clear_axis_target(cmd, target)
	transition_axis_target(
		cmd,
		target,
		"transfer_dst_optimal",
		"fragment_shader",
		"transfer",
		"shader_read",
		"transfer_write"
	)
	cmd:ClearColorImage{
		image = target.texture:GetImage(),
		color = {0, 0, 0, 0},
		base_array_layer = 0,
		layer_count = target.texture:GetHeight(),
	}
	transition_axis_target(
		cmd,
		target,
		"shader_read_only_optimal",
		"transfer",
		"fragment_shader",
		"transfer_write",
		"shader_read"
	)
end

local function get_axis_scroll_offsets(axis_name, delta)
	if axis_name == "x" then return delta.z, delta.y, -delta.x end

	if axis_name == "y" then return delta.x, -delta.z, -delta.y end

	return delta.x, delta.y, -delta.z
end

local function get_scroll_copy_bounds(offset, resolution)
	local size = resolution - math.abs(offset)

	if size <= 0 then return nil end

	return math.max(0, -offset), math.max(0, offset), size
end

local function build_axis_scroll_copy_config(axis_name, resolution, delta)
	local offset_x, offset_y, offset_layer = get_axis_scroll_offsets(axis_name, delta)
	local src_x, dst_x, width = get_scroll_copy_bounds(offset_x, resolution)
	local src_y, dst_y, height = get_scroll_copy_bounds(offset_y, resolution)
	local src_layer, dst_layer, layer_count = get_scroll_copy_bounds(offset_layer, resolution)

	if not src_x or not src_y or not src_layer then return nil end

	return {
		src_x = src_x,
		src_y = src_y,
		dst_x = dst_x,
		dst_y = dst_y,
		width = width,
		height = height,
		src_base_array_layer = src_layer,
		dst_base_array_layer = dst_layer,
		layer_count = layer_count,
	}
end

local function scroll_axis_target(cmd, source_target, target, copy_config, descriptor_slot)
	local pipeline = shared_scroll_compute_pipeline or get_scroll_compute_pipeline()
	transition_axis_target_for_compute(cmd, source_target, false)
	transition_axis_target_for_compute(cmd, target, true)
	pipeline.current_scroll_copy = copy_config
	pipeline:UpdateDescriptorSet("storage_image", descriptor_slot, 0, 0, source_target.texture:GetView())
	pipeline:UpdateDescriptorSet("storage_image", descriptor_slot, 1, 0, target.texture:GetView())
	pipeline:DispatchForSize(
		cmd,
		target.texture:GetWidth(),
		target.texture:GetHeight(),
		target.texture:GetHeight(),
		descriptor_slot
	)
	pipeline.current_scroll_copy = nil
	transition_axis_target_from_compute(cmd, source_target)
	transition_axis_target_from_compute(cmd, target)
end

local function scroll_clipmap_targets(_, voxelizer, clipmap_index, pending_scroll)
	local compute_cmd = render.GetCommandBufferOutsideRendering()
	local own_compute_cmd = false

	if not compute_cmd then
		compute_cmd = render.GetCommandPool():AllocateCommandBuffer()
		compute_cmd:Begin()
		own_compute_cmd = true
	elseif voxelizer and voxelizer.AddInlineScrollWork then
		voxelizer.AddInlineScrollWork(1)
	end

	local frame_slot_base = ((render.GetCurrentFrame() or 1) - 1) * 9

	for axis_index, axis_name in ipairs({"x", "y", "z"}) do
		local source_target = voxelizer.GetClipmapAxisTarget(clipmap_index, axis_name)
		local target = voxelizer.GetClipmapScrollTarget(clipmap_index, axis_name)
		local copy_config = build_axis_scroll_copy_config(axis_name, target.texture:GetHeight(), pending_scroll.delta)
		local descriptor_slot = frame_slot_base + (clipmap_index - 1) * 3 + axis_index
		scroll_axis_target(compute_cmd, source_target, target, copy_config, descriptor_slot)
	end

	if own_compute_cmd then
		compute_cmd:End()
		submit_voxel_scroll_command_buffer(voxelizer, compute_cmd)
	end
end

local function get_voxel_projection_view_world_matrix()
	local world_matrix = render3d.GetWorldMatrix()
	world_matrix:GetMultiplied(current_build_state.view_matrix, current_build_state.projection_view_world)
	current_build_state.projection_view_world:GetMultiplied(current_build_state.projection_matrix, current_build_state.projection_view_world)
	return current_build_state.projection_view_world
end

local function update_slice_transform(clipmap, axis_name, slice, build_origin)
	local slice_center = ((slice + 0.5) - clipmap.resolution * 0.5) * clipmap.voxel_size
	local view_center = current_build_state.clipmap_origin
	view_center.x = build_origin.x
	view_center.y = build_origin.y
	view_center.z = build_origin.z

	if axis_name == "x" then
		view_center.x = view_center.x + slice_center
	elseif axis_name == "y" then
		view_center.y = view_center.y + slice_center
	else
		view_center.z = view_center.z + slice_center
	end

	current_build_state.view_matrix = Matrix44()
	current_build_state.view_matrix:Translate(-view_center.x, -view_center.y, -view_center.z)
	current_build_state.view_matrix:Multiply(AXIS_ROTATIONS[axis_name]:GetConjugated():GetMatrix())
	current_build_state.projection_matrix = Matrix44()
	current_build_state.projection_matrix:Ortho(
		-clipmap.world_span * 0.5,
		clipmap.world_span * 0.5,
		-clipmap.world_span * 0.5,
		clipmap.world_span * 0.5,
		-math.max(clipmap.voxel_size * 0.5, 0.001),
		math.max(clipmap.voxel_size * 0.5, 0.001),
		true
	)
end

local function upload_voxel_build_constants(self)
	self:UploadConstants()
end

local function push_voxel_vertex_constants(self, cmd, world_matrix)
	local constants = self._voxel_vertex_push_constants

	if not constants then
		constants = self:GetPushConstantBlockType("vertex")()
		self._voxel_vertex_push_constants = constants
		self._voxel_vertex_push_offset = self:GetPushConstantBlockOffset("vertex")
	end

	current_build_state.projection_view_world:CopyToFloatPointer(constants.projection_view_world)
	world_matrix:CopyToFloatPointer(constants.world)
	self:PushConstants(cmd, {"vertex"}, self._voxel_vertex_push_offset, constants)
end

local TRANSFORMED_AABB_CORNERS = {
	Vec3(),
	Vec3(),
	Vec3(),
	Vec3(),
	Vec3(),
	Vec3(),
	Vec3(),
	Vec3(),
}

local function reset_aabb(target)
	target.min_x = math.huge
	target.min_y = math.huge
	target.min_z = math.huge
	target.max_x = -math.huge
	target.max_y = -math.huge
	target.max_z = -math.huge
	return target
end

local function build_world_aabb_from_local_aabb(local_aabb, local_to_world, target)
	if not local_aabb then return nil end

	if not local_to_world then return local_aabb end

	local corners = TRANSFORMED_AABB_CORNERS
	corners[1].x, corners[1].y, corners[1].z = local_aabb.min_x, local_aabb.min_y, local_aabb.min_z
	corners[2].x, corners[2].y, corners[2].z = local_aabb.min_x, local_aabb.min_y, local_aabb.max_z
	corners[3].x, corners[3].y, corners[3].z = local_aabb.min_x, local_aabb.max_y, local_aabb.min_z
	corners[4].x, corners[4].y, corners[4].z = local_aabb.min_x, local_aabb.max_y, local_aabb.max_z
	corners[5].x, corners[5].y, corners[5].z = local_aabb.max_x, local_aabb.min_y, local_aabb.min_z
	corners[6].x, corners[6].y, corners[6].z = local_aabb.max_x, local_aabb.min_y, local_aabb.max_z
	corners[7].x, corners[7].y, corners[7].z = local_aabb.max_x, local_aabb.max_y, local_aabb.min_z
	corners[8].x, corners[8].y, corners[8].z = local_aabb.max_x, local_aabb.max_y, local_aabb.max_z
	local world_aabb = reset_aabb(
		target or
			AABB(math.huge, math.huge, math.huge, -math.huge, -math.huge, -math.huge)
	)

	for i = 1, 8 do
		local point = local_to_world:TransformVector(corners[i])
		world_aabb:ExpandVec3(point)
	end

	return world_aabb
end

local function clamp_slice_index(index, resolution)
	if index < 0 then return 0 end

	if index >= resolution then return resolution - 1 end

	return index
end

local function build_entry_slice_range(entry_world_aabb, clipmap, build_origin, axis_name)
	local half_span = clipmap.world_span * 0.5
	local voxel_size = clipmap.voxel_size
	local min_corner = build_origin[axis_name] - half_span
	local max_corner = build_origin[axis_name] + half_span
	local axis_min_key = "min_" .. axis_name
	local axis_max_key = "max_" .. axis_name
	local axis_min = entry_world_aabb[axis_min_key]
	local axis_max = entry_world_aabb[axis_max_key]

	if axis_max < min_corner or axis_min > max_corner then return false end

	local start_slice = clamp_slice_index(math.floor((axis_min - min_corner) / voxel_size), clipmap.resolution)
	local end_slice = clamp_slice_index(math.floor(((axis_max - min_corner) / voxel_size) - 1e-6), clipmap.resolution)

	if end_slice < start_slice then end_slice = start_slice end

	return {
		start_slice = start_slice,
		end_slice = end_slice,
	}
end

local function is_component_frame_dynamic(component)
	local owner = component and component.Owner

	if owner and owner.rigid_body then return true end

	local transform = owner and owner.transform
	return transform and transform.IsFrameDynamic and transform:IsFrameDynamic() or false
end

local function build_voxel_draw_list(voxelizer, clipmap_index, clipmap)
	local visuals = voxelizer.GetClipmapVisibleVisuals(clipmap_index)
	local draw_list = {}
	local submitted_visuals = 0
	local submitted_entries = 0
	local build_origin = clipmap.build_origin or clipmap.origin
	local default_material = render3d.GetDefaultMaterial()
	local cacheable = true

	for _, component in ipairs(visuals) do
		if component.Visible and component:IsWithinCullDistance() then
			if cacheable and is_component_frame_dynamic(component) then cacheable = false end

			local component_entries = 0
			local component_world_matrix = component:GetWorldMatrix()
			local material_override = component.MaterialOverride

			for _, entry in ipairs(component:GetRenderEntries()) do
				local transform = entry.transform
				local world_matrix = transform and transform:GetWorldMatrix() or component_world_matrix

				if world_matrix then
					local material = material_override or entry.material or default_material

					if voxelizer.ShouldVoxelizeMaterial(material) then
						local local_aabb = entry.polygon3d and entry.polygon3d.GetAABB and entry.polygon3d:GetAABB() or nil
						local world_aabb = nil

						if local_aabb then
							if
								entry.voxel_world_aabb_cache and
								entry.voxel_world_aabb_cache_matrix == world_matrix and
								entry.voxel_world_aabb_cache_source == local_aabb
							then
								world_aabb = entry.voxel_world_aabb_cache
							else
								world_aabb = build_world_aabb_from_local_aabb(local_aabb, world_matrix, entry.voxel_world_aabb_cache)
								entry.voxel_world_aabb_cache = world_aabb
								entry.voxel_world_aabb_cache_matrix = world_matrix
								entry.voxel_world_aabb_cache_source = local_aabb
							end
						end

						if
							world_aabb and
							clipmap.build_world_aabb and
							clipmap.build_world_aabb:IsBoxIntersecting(world_aabb)
						then
							local slice_ranges = {
								x = build_entry_slice_range(world_aabb, clipmap, build_origin, "x"),
								y = build_entry_slice_range(world_aabb, clipmap, build_origin, "y"),
								z = build_entry_slice_range(world_aabb, clipmap, build_origin, "z"),
							}

							if slice_ranges.x or slice_ranges.y or slice_ranges.z then
								local material_key = material.upload_cache_key or material
								local polygon_key = entry.polygon3d
								draw_list[#draw_list + 1] = {
									polygon3d = entry.polygon3d,
									world_matrix = world_matrix,
									material = material,
									slice_ranges = slice_ranges,
									material_sort_id = get_voxel_draw_sort_id(material_key),
									polygon_sort_id = get_voxel_draw_sort_id(polygon_key),
								}
								component_entries = component_entries + 1
								submitted_entries = submitted_entries + 1
							end
						end
					end
				end
			end

			if component_entries > 0 then submitted_visuals = submitted_visuals + 1 end
		end
	end

	if #draw_list > 1 then table.sort(draw_list, compare_voxel_draw_entries) end

	return draw_list, submitted_visuals, submitted_entries, cacheable
end

local function get_voxel_slice_bucket(slice_buckets, axis_name, slice)
	local axis_buckets = slice_buckets and slice_buckets[axis_name] or nil

	if not axis_buckets then return nil end

	return axis_buckets[slice]
end

local function draw_voxel_slice_geometry(self, cmd, clipmap_index, clipmap, axis_name, slice, draw_list)
	local build_origin = clipmap.build_origin or clipmap.origin
	current_build_state.clipmap_index = clipmap_index
	current_build_state.axis_index = get_axis_index(axis_name)
	current_build_state.current_slice = slice
	current_build_state.resolution = clipmap.resolution
	current_build_state.voxel_size = clipmap.voxel_size
	current_build_state.world_span = clipmap.world_span
	current_build_state.clipmap_origin.x = build_origin.x
	current_build_state.clipmap_origin.y = build_origin.y
	current_build_state.clipmap_origin.z = build_origin.z
	update_slice_transform(clipmap, axis_name, slice, build_origin)
	draw_list = draw_list or {}
	local last_polygon3d = nil
	local last_material = nil

	for _, entry in ipairs(draw_list) do
		render3d.SetWorldMatrix(entry.world_matrix)

		if entry.polygon3d ~= last_polygon3d then
			render3d.SetCurrentPolygon3D(entry.polygon3d)
			last_polygon3d = entry.polygon3d
		end

		if entry.material ~= last_material then
			render3d.SetMaterial(entry.material)
			last_material = entry.material
			upload_voxel_build_constants(self)
		end

		push_voxel_vertex_constants(self, cmd, entry.world_matrix)
		entry.polygon3d:Draw()
	end

	return #draw_list
end

local function slice_has_geometry(axis_name, slice, draw_list)
	local axis_buckets = draw_list and draw_list[axis_name] or nil
	local bucket = axis_buckets and axis_buckets[slice] or nil
	return bucket ~= nil and bucket[1] ~= nil
end

local function draw_dirty_voxel_slice(axis_name, target, slice, dirty_range, current_clipmap)
	local state = current_slice_draw_state
	local cmd = state.cmd
	local repair = state.voxelizer.GetClipmapDirtySliceRepair and
		state.voxelizer.GetClipmapDirtySliceRepair(state.clipmap_index, axis_name, slice) or
		nil
	local full_slice_repair = repair == nil or repair.full == true
	local build_target_cleared = current_clipmap.build_target_cleared == true
	local slice_draw_list = get_voxel_slice_bucket(state.slice_buckets, axis_name, slice)
	local has_geometry = slice_draw_list ~= nil and slice_draw_list[1] ~= nil

	if build_target_cleared and not has_geometry then return end

	if not state.axis_transitioned[axis_name] then
		transition_axis_target(
			cmd,
			target,
			"color_attachment_optimal",
			"fragment_shader",
			"color_attachment_output",
			"shader_read",
			"color_attachment_write"
		)
		state.axis_transitioned[axis_name] = true
	end

	cmd:BeginRendering{
		color_attachments = {
			{
				color_image_view = target.layer_views[slice],
				clear_color = {0, 0, 0, 0},
				load_op = (
						not build_target_cleared and
						(
							current_clipmap.full_rebuild or
							current_clipmap.clear_dirty_slices or
							full_slice_repair
						)
					)
					and
					"clear" or
					"load",
				store_op = "store",
			},
		},
		w = current_clipmap.resolution,
		h = current_clipmap.resolution,
	}
	cmd:SetViewport(0, 0, current_clipmap.resolution, current_clipmap.resolution, 0, 1)

	if full_slice_repair then
		cmd:SetScissor(0, 0, current_clipmap.resolution, current_clipmap.resolution)
		draw_voxel_slice_geometry(
			state.self,
			cmd,
			state.clipmap_index,
			current_clipmap,
			axis_name,
			slice,
			slice_draw_list
		)
	else
		for _, rect in ipairs(repair.rects or {}) do
			if not build_target_cleared then
				cmd:ClearAttachments{
					color = {0, 0, 0, 0},
					x = rect.x,
					y = rect.y,
					w = rect.w,
					h = rect.h,
				}
			end

			cmd:SetScissor(rect.x, rect.y, rect.w, rect.h)
			draw_voxel_slice_geometry(
				state.self,
				cmd,
				state.clipmap_index,
				current_clipmap,
				axis_name,
				slice,
				slice_draw_list
			)
		end
	end

	cmd:EndRendering()
end

local function draw_voxel_build(self, cmd)
	local voxelizer = render3d.GetSceneVoxelizer()

	if not voxelizer or not voxelizer.IsEnabled or not voxelizer:IsEnabled() then
		return
	end

	voxelizer.BeginBuildFrame()
	local total_visuals = 0
	local total_entries = 0

	for clipmap_index = 1, voxelizer.clipmap_count or 0 do
		local clipmap = voxelizer.GetClipmap(clipmap_index)

		if clipmap and clipmap.dirty then
			local pending_scroll = voxelizer.ConsumeClipmapScroll and
				voxelizer.ConsumeClipmapScroll(clipmap_index) or
				nil

			if pending_scroll then
				scroll_clipmap_targets(cmd, voxelizer, clipmap_index, pending_scroll)

				if voxelizer.MarkClipmapScrollReady then
					voxelizer.MarkClipmapScrollReady(clipmap_index)
				end

				clipmap = voxelizer.GetClipmap(clipmap_index)
			end

			local build_origin = clipmap.build_origin or clipmap.origin
			local scene_version = Visual.GetSceneAccelerationVersion and Visual.GetSceneAccelerationVersion() or 0
			local cache = clipmap.voxel_draw_cache
			local cache_valid = cache and
				cache.scene_version == scene_version and
				cache.build_origin_x == build_origin.x and
				cache.build_origin_y == build_origin.y and
				cache.build_origin_z == build_origin.z
			local draw_list
			local slice_buckets
			local clipmap_visuals
			local clipmap_entries

			if cache_valid then
				draw_list = cache.draw_list
				slice_buckets = cache.slice_buckets
				clipmap_visuals = cache.submitted_visuals
				clipmap_entries = cache.submitted_entries
			else
				local cacheable
				draw_list, clipmap_visuals, clipmap_entries, cacheable = build_voxel_draw_list(voxelizer, clipmap_index, clipmap)
				slice_buckets = create_voxel_slice_buckets(draw_list, clipmap)

				if cacheable then
					clipmap.voxel_draw_cache = {
						scene_version = scene_version,
						build_origin_x = build_origin.x,
						build_origin_y = build_origin.y,
						build_origin_z = build_origin.z,
						draw_list = draw_list,
						slice_buckets = slice_buckets,
						submitted_visuals = clipmap_visuals,
						submitted_entries = clipmap_entries,
					}
				else
					clipmap.voxel_draw_cache = nil
				end
			end

			if
				voxelizer.ConsumeClipmapClearPending and
				voxelizer.ConsumeClipmapClearPending(clipmap_index)
			then
				for _, axis_name in ipairs({"x", "y", "z"}) do
					clear_axis_target(cmd, voxelizer.GetClipmapBuildAxisTarget(clipmap_index, axis_name))
				end
			end

			local axis_transitioned = {}
			current_slice_draw_state.self = self
			current_slice_draw_state.cmd = cmd
			current_slice_draw_state.voxelizer = voxelizer
			current_slice_draw_state.clipmap_index = clipmap_index
			current_slice_draw_state.draw_list = draw_list
			current_slice_draw_state.slice_buckets = slice_buckets
			current_slice_draw_state.axis_transitioned = axis_transitioned
			local dirty_axes, dirty_slices, build_complete = voxelizer.ForEachDirtyAxisTarget(
				clipmap_index,
				voxelizer.GetClipmapBuildSliceBudget and
					voxelizer.GetClipmapBuildSliceBudget(clipmap_index) or
					voxelizer.build_slices_per_frame,
				draw_dirty_voxel_slice
			)
			total_visuals = total_visuals + clipmap_visuals
			total_entries = total_entries + clipmap_entries

			for axis_name in pairs(axis_transitioned) do
				transition_axis_target(
					cmd,
					voxelizer.GetClipmapBuildAxisTarget(clipmap_index, axis_name),
					"shader_read_only_optimal",
					"color_attachment_output",
					"fragment_shader",
					"color_attachment_write",
					"shader_read"
				)
			end

			if dirty_slices > 0 and build_complete then
				voxelizer.MarkClipmapBuilt(clipmap_index, dirty_axes, dirty_slices)
			elseif dirty_slices > 0 then
				voxelizer.AddBuildWork(1, dirty_axes, dirty_slices)
			end
		end
	end

	voxelizer.frame_stats.voxel_visuals = total_visuals
	voxelizer.frame_stats.voxel_entries = total_entries
end

return {
	{
		name = "voxel_build",
		ColorFormat = {{"r16g16b16a16_sfloat", {"color", "rgba"}}},
		dont_create_framebuffers = true,
		on_draw = draw_voxel_build,
		vertex = {
			bindings = {
				{
					binding = 0,
					stride = model_pipeline.GetVertexStride(),
					input_rate = "vertex",
					attributes = model_pipeline.GetVertexAttributesSubset({"position", "uv"}),
				},
			},
			outputs = {
				{"uv", "vec2"},
			},
			push_constants = {
				{
					name = "vertex",
					block = model_pipeline.GetTransformBlock(true),
					write = model_pipeline.BuildTransformBlockWriter(true, get_voxel_projection_view_world_matrix),
				},
			},
			shader = [[
				void main() {
					vec3 local_position = in_position;
					gl_Position = vertex.projection_view_world * vec4(local_position, 1.0);
					out_uv = in_uv;
				}
			]],
		},
		fragment = {
			uniform_buffers = {
				{
					name = "voxel_build_data",
					binding_index = 3,
					block = {
						{"clipmap_index", "int"},
						{"axis_index", "int"},
						{"current_slice", "int"},
						{"resolution", "int"},
						{"voxel_size", "float"},
						{"clipmap_origin", "vec3"},
						{"world_span", "float"},
					},
					write = function(self, block)
						block.clipmap_index = current_build_state.clipmap_index
						block.axis_index = current_build_state.axis_index
						block.current_slice = current_build_state.current_slice
						block.resolution = current_build_state.resolution
						block.voxel_size = current_build_state.voxel_size
						current_build_state.clipmap_origin:CopyToFloatPointer(block.clipmap_origin)
						block.world_span = current_build_state.world_span
						return block
					end,
				},
				{
					name = "surface",
					upload_scope = "frame_keyed",
					upload_key = render3d.GetMaterialUploadKey,
					block = model_pipeline.GetSurfaceMaterialBlock(),
					write = model_pipeline.WriteSurfaceMaterialBlock,
				},
			},
			shader = model_pipeline.BuildSurfaceSamplingGlsl("surface") .. [[
			void main() {
				vec4 surface_color = get_surface_color();
				discard_surface_alpha(surface_color);
				vec3 albedo = clamp(surface_color.rgb, vec3(0.0), vec3(1.0));
				vec3 emissive = clamp(get_surface_emissive(albedo), vec3(0.0), vec3(1.0));
				vec3 voxel_color = clamp(albedo + emissive, vec3(0.0), vec3(1.0));
				set_color(vec4(voxel_color, 1.0));
			}
			]],
		},
		CullMode = "none",
		DepthTest = false,
		DepthWrite = false,
		Blend = true,
		SrcColorBlendFactor = "one",
		DstColorBlendFactor = "one",
		ColorBlendOp = "max",
		SrcAlphaBlendFactor = "one",
		DstAlphaBlendFactor = "one",
		AlphaBlendOp = "max",
		ColorWriteMask = {"r", "g", "b", "a"},
	},
}
