local render = import("goluwa/render/render.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local orientation = import("goluwa/render3d/orientation.lua")
local model_pipeline = import("goluwa/render3d/model_pipeline.lua")
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
	clipmap_index = 0,
	draw_list = nil,
	axis_transitioned = nil,
}

local function get_axis_index(axis_name)
	if axis_name == "x" then return 0 end

	if axis_name == "y" then return 1 end

	return 2
end

local function transition_axis_target(cmd, target, new_layout, src_stage, dst_stage, src_access, dst_access)
	local image = target.texture:GetImage()
	cmd:PipelineBarrier{
		srcStage = src_stage,
		dstStage = dst_stage,
		imageBarriers = {
			{
				image = image,
				oldLayout = image.layout or "shader_read_only_optimal",
				newLayout = new_layout,
				srcAccessMask = src_access,
				dstAccessMask = dst_access,
				base_array_layer = 0,
				layer_count = target.texture:GetHeight(),
				base_mip_level = 0,
				level_count = 1,
			},
		},
	}
	image.layout = new_layout
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
	local world_aabb = reset_aabb(target or AABB(math.huge, math.huge, math.huge, -math.huge, -math.huge, -math.huge))

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

local function build_voxel_draw_list(voxelizer, clipmap_index, clipmap)
	local visuals = voxelizer.GetClipmapVisibleVisuals(clipmap_index)
	local draw_list = {}
	local submitted_visuals = 0
	local submitted_entries = 0
	local build_origin = clipmap.build_origin or clipmap.origin
	local default_material = render3d.GetDefaultMaterial()

	for _, component in ipairs(visuals) do
		if component.Visible and component:IsWithinCullDistance() then
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

						if world_aabb and clipmap.build_world_aabb and clipmap.build_world_aabb:IsBoxIntersecting(world_aabb) then
							local slice_ranges = {
								x = build_entry_slice_range(world_aabb, clipmap, build_origin, "x"),
								y = build_entry_slice_range(world_aabb, clipmap, build_origin, "y"),
								z = build_entry_slice_range(world_aabb, clipmap, build_origin, "z"),
							}

							if slice_ranges.x or slice_ranges.y or slice_ranges.z then
								draw_list[#draw_list + 1] = {
									polygon3d = entry.polygon3d,
									world_matrix = world_matrix,
									material = material,
									slice_ranges = slice_ranges,
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

	return draw_list, submitted_visuals, submitted_entries
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

	for _, entry in ipairs(draw_list) do
		local slice_range = entry.slice_ranges and entry.slice_ranges[axis_name] or nil

		if slice_range and (slice < slice_range.start_slice or slice > slice_range.end_slice) then
			goto continue
		end

		render3d.SetWorldMatrix(entry.world_matrix)
		render3d.SetCurrentPolygon3D(entry.polygon3d)
		render3d.SetMaterial(entry.material)
		upload_voxel_build_constants(self)
		entry.polygon3d:Draw()
		::continue::
	end

	return #draw_list
end

local function draw_dirty_voxel_slice(axis_name, target, slice, dirty_range, current_clipmap)
	local state = current_slice_draw_state
	local cmd = state.cmd

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
				load_op = "clear",
				store_op = "store",
			},
		},
		w = current_clipmap.resolution,
		h = current_clipmap.resolution,
	}
	cmd:SetViewport(0, 0, current_clipmap.resolution, current_clipmap.resolution, 0, 1)
	cmd:SetScissor(0, 0, current_clipmap.resolution, current_clipmap.resolution)
	draw_voxel_slice_geometry(state.self, cmd, state.clipmap_index, current_clipmap, axis_name, slice, state.draw_list)
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
			local draw_list, clipmap_visuals, clipmap_entries = build_voxel_draw_list(voxelizer, clipmap_index, clipmap)

			if voxelizer.ConsumeClipmapClearPending and voxelizer.ConsumeClipmapClearPending(clipmap_index) then
				for _, axis_name in ipairs({"x", "y", "z"}) do
					clear_axis_target(cmd, voxelizer.GetClipmapBuildAxisTarget(clipmap_index, axis_name))
				end
			end

			local axis_transitioned = {}
			current_slice_draw_state.self = self
			current_slice_draw_state.cmd = cmd
			current_slice_draw_state.clipmap_index = clipmap_index
			current_slice_draw_state.draw_list = draw_list
			current_slice_draw_state.axis_transitioned = axis_transitioned
			local dirty_axes, dirty_slices, build_complete = voxelizer.ForEachDirtyAxisTarget(
				clipmap_index,
				voxelizer.GetClipmapBuildSliceBudget and voxelizer.GetClipmapBuildSliceBudget(clipmap_index) or voxelizer.build_slices_per_frame,
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
		vertex = model_pipeline.CreateVertexStage{
			position = true,
			uv = true,
			get_projection_view_world_matrix = get_voxel_projection_view_world_matrix,
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
