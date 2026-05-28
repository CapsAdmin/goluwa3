local T = import("test/environment.lua")
local ffi = require("ffi")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Material = import("goluwa/render3d/material.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Color = import("goluwa/structs/color.lua")
local Entity = import("goluwa/ecs/entity.lua")

local function attach_visual(entity, polygon3d, material, primitive_scale)
	entity:AddComponent("visual")
	local primitive = Entity.New{
		Name = (entity:GetName() or "voxelizer") .. "_primitive",
		Parent = entity,
	}
	primitive:AddComponent("transform")
	if primitive_scale then primitive.transform:SetScale(primitive_scale) end
	local visual_primitive = primitive:AddComponent("visual_primitive")
	visual_primitive:SetPolygon3D(polygon3d)
	visual_primitive:SetMaterial(material)
	entity.visual:BuildAABB()
	entity.visual:SetUseOcclusionCulling(false)
	return entity.visual
end

local function make_box_entity(position, size, primitive_scale)
	local polygon3d = Polygon3D.New()
	polygon3d:CreateCube(size)
	polygon3d:BuildBoundingBox()
	polygon3d:Upload()
	local material = Material.New{
		ColorMultiplier = Color(1, 1, 1, 1),
		EmissiveMultiplier = Color(1, 1, 1, 1),
	}
	local entity = Entity.New{Name = "voxel_box"}
	entity:AddComponent("transform")
	entity.transform:SetPosition(position)
	attach_visual(entity, polygon3d, material, primitive_scale)
	return entity
end

local function get_axis_texture_coords(axis_name, voxel, resolution)
	local max_index = resolution - 1

	if axis_name == "x" then
		return voxel.x, max_index - voxel.z, max_index - voxel.y
	end

	if axis_name == "y" then
		return voxel.y, max_index - voxel.x, voxel.z
	end

	return voxel.z, max_index - voxel.x, max_index - voxel.y
end

local function get_downloaded_half_rgba(downloaded, x, y)
	local width = downloaded:GetWidth()
	local height = downloaded:GetHeight()

	if x < 0 or x >= width or y < 0 or y >= height then return 0, 0, 0, 0 end

	local pixels = ffi.cast("uint16_t*", downloaded.pixels)
	local offset = (y * width + x) * 4
	return pixels[offset + 0], pixels[offset + 1], pixels[offset + 2], pixels[offset + 3]
end

local function get_voxel_alpha(axis_targets, axis_name, voxel, resolution)
	local layer, x, y = get_axis_texture_coords(axis_name, voxel, resolution)
	local downloaded = axis_targets[axis_name].texture:Download{base_array_layer = layer}
	local _, _, _, alpha = get_downloaded_half_rgba(downloaded, x, y)
	return alpha
end

local function get_voxel_alpha_triplet(axis_targets, voxel, resolution)
	return {
		x = get_voxel_alpha(axis_targets, "x", voxel, resolution),
		y = get_voxel_alpha(axis_targets, "y", voxel, resolution),
		z = get_voxel_alpha(axis_targets, "z", voxel, resolution),
	}
end

local function voxel_is_occupied(axis_targets, voxel, resolution)
	for _, axis_name in ipairs({"x", "y", "z"}) do
		if get_voxel_alpha(axis_targets, axis_name, voxel, resolution) <= 0 then
			return false
		end
	end

	return true
end

local function voxel_has_any_occupancy(axis_targets, voxel, resolution)
	for _, axis_name in ipairs({"x", "y", "z"}) do
		if get_voxel_alpha(axis_targets, axis_name, voxel, resolution) > 0 then
			return true
		end
	end

	return false
end

local function get_build_axis_targets(voxelizer, clipmap_index)
	return {
		x = voxelizer.GetClipmapScrollTarget(clipmap_index, "x"),
		y = voxelizer.GetClipmapScrollTarget(clipmap_index, "y"),
		z = voxelizer.GetClipmapScrollTarget(clipmap_index, "z"),
	}
end

local function wait_for_voxelizer_build(draw, voxelizer, max_frames)
	max_frames = max_frames or 4

	for _ = 1, max_frames do
		draw()
		local clipmap = voxelizer.GetClipmap(1)

		if clipmap and not clipmap.dirty then return clipmap end
	end

	return voxelizer.GetClipmap(1)
end

local function draw_voxelizer_frames(draw, count)
	for _ = 1, count do
		draw()
	end
end

local function configure_test_voxelizer(config)
	config = config or {}
	local reset_config = {
		enabled = true,
		clipmap_count = config.clipmap_count or 1,
		base_resolution = config.base_resolution or 16,
		base_voxel_size = config.base_voxel_size or 1,
		clipmap_snap_voxel_stride = config.clipmap_snap_voxel_stride or 1,
		build_slices_per_frame = config.build_slices_per_frame or 64,
		background_build_slices_per_frame = config.background_build_slices_per_frame or 64,
	}

	for _, key in ipairs({
		"moving_build_slices_per_frame",
		"moving_background_build_slices_per_frame",
		"settled_build_slices_per_frame",
		"settled_background_build_slices_per_frame",
		"moving_max_active_clipmaps_per_frame",
		"settled_max_active_clipmaps_per_frame",
		"prefer_exposed_dirty_slices",
	}) do
		if config[key] ~= nil then reset_config[key] = config[key] end
	end

	return render3d.GetSceneVoxelizer().ResetState(reset_config)
end

local function restore_default_voxelizer(voxelizer)
	voxelizer.ResetState{
		enabled = true,
		clipmap_count = 1,
		base_resolution = 128,
		base_voxel_size = 1,
		clipmap_snap_voxel_stride = 1,
		build_slices_per_frame = 12,
		background_build_slices_per_frame = 24,
	}
end

local function assert_voxel_state(voxelizer, occupied_voxel, empty_voxels, world_position)
	local clipmap = voxelizer.GetClipmap(1)
	local axis_targets = clipmap and clipmap.resources and clipmap.resources.axis_targets
	local mapping = voxelizer.WorldToVoxel(1, world_position)
	T(mapping.inside)["=="](true)
	T(mapping.voxel.x)["=="](occupied_voxel.x)
	T(mapping.voxel.y)["=="](occupied_voxel.y)
	T(mapping.voxel.z)["=="](occupied_voxel.z)
	T(axis_targets ~= nil)["=="](true)

	if not voxel_is_occupied(axis_targets, occupied_voxel, clipmap.resolution) then
		local alpha = get_voxel_alpha_triplet(axis_targets, occupied_voxel, clipmap.resolution)
		error(
			string.format(
				"expected occupied voxel (%d,%d,%d), got alpha=(x=%d y=%d z=%d)",
				occupied_voxel.x,
				occupied_voxel.y,
				occupied_voxel.z,
				alpha.x,
				alpha.y,
				alpha.z
			),
			0
		)
	end

	for _, voxel in ipairs(empty_voxels or {}) do
		if voxel_is_occupied(axis_targets, voxel, clipmap.resolution) then
			local alpha = get_voxel_alpha_triplet(axis_targets, voxel, clipmap.resolution)
			error(
				string.format(
					"voxel (%d,%d,%d) unexpectedly occupied: alpha=(x=%d y=%d z=%d)",
					voxel.x,
					voxel.y,
					voxel.z,
					alpha.x,
					alpha.y,
					alpha.z
				),
				0
			)
		end
	end

	return clipmap
end

local function test_voxel_snap_case(name, camera_positions, expected_voxels, extra_empty_voxels_by_step)
	T.Test3D(name, function(draw)
		local camera = render3d.GetCamera()
		camera:SetFOV(math.rad(90))
		camera:SetNearZ(0.1)
		camera:SetFarZ(100)
		camera:SetRotation(Quat():Identity())

		local voxelizer = configure_test_voxelizer()
		local box_center = voxelizer.VoxelToWorld(1, expected_voxels[1])
		local entity = make_box_entity(box_center, 0.2)
		local ok, err = xpcall(function()
			for index, camera_position in ipairs(camera_positions) do
				camera:SetPosition(camera_position)
				voxelizer.Update(camera_position)
				local clipmap = wait_for_voxelizer_build(draw, voxelizer)
				T(clipmap ~= nil)["=="](true)
				T(clipmap.dirty)["=="](false)

				local occupied_voxel = expected_voxels[index]
				local empty_voxels = {}
				local function add_empty_voxel(voxel)
					if not voxel then return end

					if voxel.x == occupied_voxel.x and voxel.y == occupied_voxel.y and voxel.z == occupied_voxel.z then
						return
					end

					for _, existing in ipairs(empty_voxels) do
						if existing.x == voxel.x and existing.y == voxel.y and existing.z == voxel.z then return end
					end

					empty_voxels[#empty_voxels + 1] = voxel
				end

				add_empty_voxel(expected_voxels[index - 1])

				add_empty_voxel(expected_voxels[index + 1])

				for _, voxel in ipairs(extra_empty_voxels_by_step and extra_empty_voxels_by_step[index] or {}) do
					add_empty_voxel(voxel)
				end

				assert_voxel_state(voxelizer, occupied_voxel, empty_voxels, box_center)
			end
		end, debug.traceback)

		if entity and entity.IsValid and entity:IsValid() then entity:Remove() end

		restore_default_voxelizer(voxelizer)

		if not ok then error(err, 0) end
	end)
end

test_voxel_snap_case(
	"Graphics render3d voxelizer writes a centered box to the expected voxel",
	{
		Vec3(0, 0, 0),
	},
	{
		Vec3(11, 9, 7),
	}
)

test_voxel_snap_case(
	"Graphics render3d voxelizer leaves adjacent X voxels empty at rest",
	{
		Vec3(0, 0, 0),
	},
	{
		Vec3(11, 9, 7),
	},
	{
		{
			Vec3(10, 9, 7),
			Vec3(12, 9, 7),
		},
	}
)

test_voxel_snap_case(
	"Graphics render3d voxelizer keeps occupancy stable before the snap boundary and shifts by one voxel after +X snap",
	{
		Vec3(0, 0, 0),
		Vec3(0.49, 0, 0),
		Vec3(1.01, 0, 0),
	},
	{
		Vec3(11, 9, 7),
		Vec3(11, 9, 7),
		Vec3(10, 9, 7),
	}
)

test_voxel_snap_case(
	"Graphics render3d voxelizer shifts by one voxel after direct +X snap",
	{
		Vec3(0, 0, 0),
		Vec3(1.01, 0, 0),
	},
	{
		Vec3(11, 9, 7),
		Vec3(10, 9, 7),
	}
)

test_voxel_snap_case(
	"Graphics render3d voxelizer shifts by one voxel at exact +X boundary",
	{
		Vec3(0, 0, 0),
		Vec3(1.0, 0, 0),
	},
	{
		Vec3(11, 9, 7),
		Vec3(10, 9, 7),
	}
)

test_voxel_snap_case(
	"Graphics render3d voxelizer shifts by one voxel after -X snap",
	{
		Vec3(0, 0, 0),
		Vec3(-0.01, 0, 0),
	},
	{
		Vec3(11, 9, 7),
		Vec3(12, 9, 7),
	}
)

test_voxel_snap_case(
	"Graphics render3d voxelizer shifts by one voxel at exact -X boundary",
	{
		Vec3(0, 0, 0),
		Vec3(-1.0, 0, 0),
	},
	{
		Vec3(11, 9, 7),
		Vec3(12, 9, 7),
	}
)

test_voxel_snap_case(
	"Graphics render3d voxelizer shifts by one voxel after +Y snap",
	{
		Vec3(0, 0, 0),
		Vec3(0, 1.01, 0),
	},
	{
		Vec3(11, 9, 7),
		Vec3(11, 8, 7),
	}
)

test_voxel_snap_case(
	"Graphics render3d voxelizer shifts by one voxel at exact +Y boundary",
	{
		Vec3(0, 0, 0),
		Vec3(0, 1.0, 0),
	},
	{
		Vec3(11, 9, 7),
		Vec3(11, 8, 7),
	}
)

test_voxel_snap_case(
	"Graphics render3d voxelizer shifts by one voxel after +Z snap",
	{
		Vec3(0, 0, 0),
		Vec3(0, 0, 1.01),
	},
	{
		Vec3(11, 9, 7),
		Vec3(11, 9, 6),
	}
)

test_voxel_snap_case(
	"Graphics render3d voxelizer shifts by one voxel at exact +Z boundary",
	{
		Vec3(0, 0, 0),
		Vec3(0, 0, 1.0),
	},
	{
		Vec3(11, 9, 7),
		Vec3(11, 9, 6),
	}
)

test_voxel_snap_case(
	"Graphics render3d voxelizer shifts by one voxel per axis at exact +XYZ corner boundary",
	{
		Vec3(0, 0, 0),
		Vec3(1.0, 1.0, 1.0),
	},
	{
		Vec3(11, 9, 7),
		Vec3(10, 8, 6),
	}
)

T.Test3D("Graphics render3d voxelizer commits the latest scrolled origin once scroll build completes", function(draw)
	local camera = render3d.GetCamera()
	camera:SetFOV(math.rad(90))
	camera:SetNearZ(0.1)
	camera:SetFarZ(100)
	camera:SetRotation(Quat():Identity())

	local voxelizer = configure_test_voxelizer{
		base_resolution = 4,
		build_slices_per_frame = 1,
		background_build_slices_per_frame = 1,
	}
	local ok, err = xpcall(function()
		camera:SetPosition(Vec3(0, 0, 0))
		voxelizer.Update(Vec3(0, 0, 0))
		local clipmap = wait_for_voxelizer_build(draw, voxelizer, 32)
		T(clipmap ~= nil)["=="](true)
		T(clipmap.dirty)["=="](false)
		T(clipmap.origin.x)["=="](0)

		camera:SetPosition(Vec3(1.01, 0, 0))
		voxelizer.Update(Vec3(1.01, 0, 0))
		clipmap = voxelizer.GetClipmap(1)
		T(clipmap.building_into_scroll)["=="](true)
		T(clipmap.build_origin.x)["=="](1)
		T(clipmap.origin.x)["=="](0)

		clipmap = wait_for_voxelizer_build(draw, voxelizer, 24)
		T(clipmap.origin.x)["=="](1)
		T(clipmap.building_into_scroll)["=="](false)

		camera:SetPosition(Vec3(5.01, 0, 0))
		voxelizer.Update(Vec3(5.01, 0, 0))
		clipmap = voxelizer.GetClipmap(1)
		T(clipmap.build_origin.x)["=="](5)

		clipmap = wait_for_voxelizer_build(draw, voxelizer, 24)
		T(clipmap.origin.x)["=="](5)
		T(clipmap.building_into_scroll)["=="](false)

		draw_voxelizer_frames(draw, 24)
		clipmap = voxelizer.GetClipmap(1)
		T(clipmap.dirty)["=="](false)
		T(clipmap.origin.x)["=="](5)
	end, debug.traceback)

	restore_default_voxelizer(voxelizer)

	if not ok then error(err, 0) end
end)

T.Test3D("Graphics render3d voxelizer rebuilds for newly added visuals without camera motion", function(draw)
	local camera = render3d.GetCamera()
	camera:SetFOV(math.rad(90))
	camera:SetNearZ(0.1)
	camera:SetFarZ(100)
	camera:SetRotation(Quat():Identity())
	camera:SetPosition(Vec3(0, 0, 0))

	local voxelizer = configure_test_voxelizer()
	voxelizer.Update(camera:GetPosition())
	local initial = wait_for_voxelizer_build(draw, voxelizer, 8)
	T(initial ~= nil)["=="](true)
	T(initial.dirty)["=="](false)

	local occupied_voxel = Vec3(8, 8, 8)
	local box_center = voxelizer.VoxelToWorld(1, occupied_voxel)
	local entity = make_box_entity(box_center, 0.2)

	local ok, err = xpcall(function()
		local rebuilt = wait_for_voxelizer_build(draw, voxelizer, 8)
		T(rebuilt ~= nil)["=="](true)
		T(rebuilt.dirty)["=="](false)
		assert_voxel_state(voxelizer, occupied_voxel, nil, box_center)
	end, debug.traceback)

	entity:Remove()
	restore_default_voxelizer(voxelizer)

	if not ok then error(err, 0) end
end)

T.Test3D("Graphics render3d voxelizer interleaves dirty slices across axes within a frame budget", function()
	local voxelizer = configure_test_voxelizer{
		base_resolution = 4,
		build_slices_per_frame = 4,
		background_build_slices_per_frame = 4,
	}
	local ok, err = xpcall(function()
		voxelizer.Update(Vec3(0, 0, 0))
		local visited = {}
		local dirty_axes, dirty_slices, build_complete = voxelizer.ForEachDirtyAxisTarget(1, 4, function(axis_name, _, slice)
			visited[#visited + 1] = axis_name .. tostring(slice)
		end)

		T(dirty_axes)["=="](3)
		T(dirty_slices)["=="](4)
		T(build_complete)["=="](false)
		T(table.concat(visited, ","))["=="]("x0,y0,z0,x1")
	end, debug.traceback)

	restore_default_voxelizer(voxelizer)

	if not ok then error(err, 0) end
end)

T.Test3D("Graphics render3d voxelizer transports exposed slab repairs after clipmap scroll", function()
	local voxelizer = configure_test_voxelizer{
		base_resolution = 4,
		base_voxel_size = 1,
		build_slices_per_frame = 4,
		background_build_slices_per_frame = 4,
	}
	local ok, err = xpcall(function()
		voxelizer.Update(Vec3(0, 0, 0))
		local clipmap = voxelizer.GetClipmap(1)
		T(clipmap ~= nil)["=="](true)
		clipmap.has_valid_data = true
		voxelizer.MarkClipmapClean(1)

		voxelizer.Update(Vec3(1.01, 0, 0))
		clipmap = voxelizer.GetClipmap(1)

		T(clipmap.pending_scroll ~= nil)["=="](true)
		T(clipmap.clear_dirty_slices)["=="](false)
		T(clipmap.building_into_scroll)["=="](true)

		local x_preserved_repair = voxelizer.GetClipmapDirtySliceRepair(1, "x", 0)
		local x_exposed_repair = voxelizer.GetClipmapDirtySliceRepair(1, "x", clipmap.resolution - 1)
		local y_repair = voxelizer.GetClipmapDirtySliceRepair(1, "y", 0)
		local z_repair = voxelizer.GetClipmapDirtySliceRepair(1, "z", 0)

		T(x_preserved_repair == nil)["=="](true)
		T(x_exposed_repair ~= nil)["=="](true)
		T(x_exposed_repair.full)["=="](true)
		T(y_repair ~= nil)["=="](true)
		T(y_repair.full)["=="](false)
		T(#(y_repair.rects or {}))["=="](1)
		T(y_repair.rects[1].x)["=="](0)
		T(y_repair.rects[1].y)["=="](0)
		T(y_repair.rects[1].w)["=="](1)
		T(y_repair.rects[1].h)["=="](clipmap.resolution)
		T(z_repair ~= nil)["=="](true)
		T(z_repair.full)["=="](false)
		T(#(z_repair.rects or {}))["=="](1)
		T(z_repair.rects[1].x)["=="](0)
		T(z_repair.rects[1].w)["=="](1)
	end, debug.traceback)

	restore_default_voxelizer(voxelizer)

	if not ok then error(err, 0) end
end)

T.Test3D("Graphics render3d voxelizer reschedules in-flight scrolls from the active origin", function()
	local voxelizer = configure_test_voxelizer{
		base_resolution = 4,
		base_voxel_size = 1,
		build_slices_per_frame = 1,
		background_build_slices_per_frame = 1,
	}
	local ok, err = xpcall(function()
		voxelizer.Update(Vec3(0, 0, 0))
		local clipmap = voxelizer.GetClipmap(1)
		T(clipmap ~= nil)["=="](true)
		clipmap.has_valid_data = true
		voxelizer.MarkClipmapClean(1)

		voxelizer.Update(Vec3(1.01, 0, 0))
		clipmap = voxelizer.GetClipmap(1)
		T(clipmap.pending_scroll ~= nil)["=="](true)
		T(clipmap.origin.x)["=="](0)
		T(clipmap.build_origin.x)["=="](1)
		T(clipmap.pending_scroll.delta.x)["=="](1)

		voxelizer.Update(Vec3(2.01, 0, 0))
		clipmap = voxelizer.GetClipmap(1)
		T(clipmap.origin.x)["=="](0)
		T(clipmap.build_origin.x)["=="](2)
		T(clipmap.pending_scroll ~= nil)["=="](true)
		T(clipmap.pending_scroll.delta.x)["=="](2)
		T(clipmap.delta.x)["=="](2)
	end, debug.traceback)

	restore_default_voxelizer(voxelizer)

	if not ok then error(err, 0) end
end)

T.Test3D("Graphics render3d voxelizer rounds exact negative one-voxel snaps correctly", function()
	local voxelizer = configure_test_voxelizer{
		base_resolution = 4,
		base_voxel_size = 0.5,
		build_slices_per_frame = 1,
		background_build_slices_per_frame = 1,
	}
	local ok, err = xpcall(function()
		voxelizer.Update(Vec3(0.1, 0, 0))
		local clipmap = voxelizer.GetClipmap(1)
		T(clipmap ~= nil)["=="](true)
		clipmap.has_valid_data = true
		voxelizer.MarkClipmapClean(1)

		voxelizer.Update(Vec3(-0.01, 0, 0))
		clipmap = voxelizer.GetClipmap(1)
		T(clipmap.origin.x)["=="](0)
		T(clipmap.build_origin.x)["=="](-0.5)
		T(clipmap.delta.x)["=="](-1)
		T(clipmap.pending_scroll ~= nil)["=="](true)
		T(clipmap.pending_scroll.delta.x)["=="](-1)
	end, debug.traceback)

	restore_default_voxelizer(voxelizer)

	if not ok then error(err, 0) end
end)

T.Test3D("Graphics render3d voxelizer keeps an in-flight scroll when the target origin is unchanged", function()
	local voxelizer = configure_test_voxelizer{
		base_resolution = 4,
		base_voxel_size = 1,
		build_slices_per_frame = 1,
		background_build_slices_per_frame = 1,
	}
	local ok, err = xpcall(function()
		voxelizer.Update(Vec3(0, 0, 0))
		local clipmap = voxelizer.GetClipmap(1)
		T(clipmap ~= nil)["=="](true)
		clipmap.has_valid_data = true
		voxelizer.MarkClipmapClean(1)

		voxelizer.Update(Vec3(1.01, 0, 0))
		clipmap = voxelizer.GetClipmap(1)
		T(clipmap.pending_scroll ~= nil)["=="](true)
		T(clipmap.build_origin.x)["=="](1)

		local pending_scroll = voxelizer.ConsumeClipmapScroll(1)
		T(pending_scroll ~= nil)["=="](true)
		T(clipmap.pending_scroll == nil)["=="](true)

		voxelizer.ForEachDirtyAxisTarget(1, 1, function() end)
		T(clipmap.pending_dirty_slices ~= nil)["=="](true)

		voxelizer.Update(Vec3(1.01, 0, 0))
		clipmap = voxelizer.GetClipmap(1)
		T(clipmap.building_into_scroll)["=="](true)
		T(clipmap.build_origin.x)["=="](1)
		T(clipmap.pending_scroll == nil)["=="](true)
		T(clipmap.pending_dirty_slices ~= nil)["=="](true)
	end, debug.traceback)

	restore_default_voxelizer(voxelizer)

	if not ok then error(err, 0) end
end)

T.Test3D("Graphics render3d voxelizer exposes scrolled build targets only after scroll copy completes", function()
	local voxelizer = configure_test_voxelizer{
		base_resolution = 4,
		base_voxel_size = 1,
		build_slices_per_frame = 1,
		background_build_slices_per_frame = 1,
	}
	local ok, err = xpcall(function()
		voxelizer.Update(Vec3(0, 0, 0))
		local clipmap = voxelizer.GetClipmap(1)
		T(clipmap ~= nil)["=="](true)
		clipmap.has_valid_data = true
		voxelizer.MarkClipmapClean(1)

		local active_x = voxelizer.GetClipmapAxisTarget(1, "x")
		local active_origin = Vec3(clipmap.origin.x, clipmap.origin.y, clipmap.origin.z)

		voxelizer.Update(Vec3(1.01, 0, 0))
		clipmap = voxelizer.GetClipmap(1)
		local build_x = voxelizer.GetClipmapScrollTarget(1, "x")
		T(clipmap.building_into_scroll)["=="](true)
		T(clipmap.build_scroll_ready)["=="](false)
		T(voxelizer.GetClipmapLightingAxisTarget(1, "x"))["=="](active_x)
		T(voxelizer.GetClipmapLightingOrigin(1).x)["=="](active_origin.x)

		voxelizer.MarkClipmapScrollReady(1)
		clipmap = voxelizer.GetClipmap(1)
		T(clipmap.build_scroll_ready)["=="](true)
		T(voxelizer.GetClipmapLightingAxisTarget(1, "x"))["=="](build_x)
		T(voxelizer.GetClipmapLightingOrigin(1).x)["=="](clipmap.build_origin.x)
	end, debug.traceback)

	restore_default_voxelizer(voxelizer)

	if not ok then error(err, 0) end
end)

T.Test3D("Graphics render3d voxelizer keeps a scroll-ready build origin latched until commit", function()
	local voxelizer = configure_test_voxelizer{
		base_resolution = 4,
		base_voxel_size = 1,
		build_slices_per_frame = 1,
		background_build_slices_per_frame = 1,
	}
	local ok, err = xpcall(function()
		voxelizer.Update(Vec3(0, 0, 0))
		local clipmap = voxelizer.GetClipmap(1)
		T(clipmap ~= nil)["=="](true)
		clipmap.has_valid_data = true
		voxelizer.MarkClipmapClean(1)

		voxelizer.Update(Vec3(1.01, 0, 0))
		clipmap = voxelizer.GetClipmap(1)
		T(clipmap.build_origin.x)["=="](1)

		voxelizer.MarkClipmapScrollReady(1)
		clipmap = voxelizer.GetClipmap(1)
		T(clipmap.build_scroll_ready)["=="](true)
		T(voxelizer.GetClipmapLightingOrigin(1).x)["=="](1)

		voxelizer.Update(Vec3(2.01, 0, 0))
		clipmap = voxelizer.GetClipmap(1)
		T(clipmap.build_scroll_ready)["=="](true)
		T(clipmap.build_origin.x)["=="](1)
		T(voxelizer.GetClipmapLightingOrigin(1).x)["=="](1)
		T(clipmap.origin.x)["=="](0)
	end, debug.traceback)

	restore_default_voxelizer(voxelizer)

	if not ok then error(err, 0) end
end)

T.Test3D("Graphics render3d voxelizer boosts slice budget while sampling a scrolled build", function()
	local voxelizer = configure_test_voxelizer{
		base_resolution = 8,
		base_voxel_size = 1,
		build_slices_per_frame = 2,
		background_build_slices_per_frame = 3,
	}
	local ok, err = xpcall(function()
		voxelizer.Update(Vec3(0, 0, 0))
		local clipmap = voxelizer.GetClipmap(1)
		T(clipmap ~= nil)["=="](true)
		clipmap.has_valid_data = true
		voxelizer.MarkClipmapClean(1)

		voxelizer.Update(Vec3(1.01, 0, 0))
		clipmap = voxelizer.GetClipmap(1)
		T(voxelizer.GetClipmapBuildSliceBudget(1))["=="](3)

		voxelizer.MarkClipmapScrollReady(1)
		clipmap = voxelizer.GetClipmap(1)
		T(clipmap.build_scroll_ready)["=="](true)
		T(voxelizer.GetClipmapBuildSliceBudget(1))["=="](3)
	end, debug.traceback)

	restore_default_voxelizer(voxelizer)

	if not ok then error(err, 0) end
end)

T.Test3D("Graphics render3d voxelizer can limit active clipmaps while moving", function()
	local voxelizer = configure_test_voxelizer{
		clipmap_count = 3,
		base_resolution = 4,
		base_voxel_size = 1,
		build_slices_per_frame = 2,
		background_build_slices_per_frame = 2,
		moving_max_active_clipmaps_per_frame = 1,
	}
	local ok, err = xpcall(function()
		voxelizer.Update(Vec3(0, 0, 0))

		for index = 1, 3 do
			local clipmap = voxelizer.GetClipmap(index)
			clipmap.has_valid_data = true
			voxelizer.MarkClipmapClean(index)
		end

		voxelizer.Update(Vec3(1.01, 0, 0))
		T(voxelizer.streaming_is_moving)["=="](true)
		T(voxelizer.GetClipmap(1).build_selected_this_frame)["=="](true)
		T(voxelizer.GetClipmap(2).build_selected_this_frame)["=="](false)
		T(voxelizer.GetClipmap(3).build_selected_this_frame)["=="](false)
		T(voxelizer.GetClipmapBuildSliceBudget(1))["=="](2)
		T(voxelizer.GetClipmapBuildSliceBudget(2))["=="](0)
		T(voxelizer.GetClipmapBuildSliceBudget(3))["=="](0)
	end, debug.traceback)

	restore_default_voxelizer(voxelizer)

	if not ok then error(err, 0) end
end)

T.Test3D("Graphics render3d voxelizer can limit active clipmaps while settled", function()
	local voxelizer = configure_test_voxelizer{
		clipmap_count = 3,
		base_resolution = 4,
		base_voxel_size = 1,
		build_slices_per_frame = 2,
		background_build_slices_per_frame = 2,
		settled_max_active_clipmaps_per_frame = 1,
	}
	local ok, err = xpcall(function()
		voxelizer.Update(Vec3(0, 0, 0))

		for index = 1, 3 do
			local clipmap = voxelizer.GetClipmap(index)
			clipmap.has_valid_data = true
			voxelizer.MarkClipmapClean(index)
		end

		voxelizer.InvalidateAll(false)
		voxelizer.Update(Vec3(0, 0, 0))
		T(voxelizer.streaming_is_moving)["=="](false)
		T(voxelizer.GetClipmap(1).build_selected_this_frame)["=="](true)
		T(voxelizer.GetClipmap(2).build_selected_this_frame)["=="](false)
		T(voxelizer.GetClipmap(3).build_selected_this_frame)["=="](false)
		T(voxelizer.GetClipmapBuildSliceBudget(1))["=="](2)
		T(voxelizer.GetClipmapBuildSliceBudget(2))["=="](0)
		T(voxelizer.GetClipmapBuildSliceBudget(3))["=="](0)
	end, debug.traceback)

	restore_default_voxelizer(voxelizer)

	if not ok then error(err, 0) end
end)

T.Test3D("Graphics render3d voxelizer can prefer exposed slices during scroll rebuilds", function()
	local voxelizer = configure_test_voxelizer{
		base_resolution = 4,
		base_voxel_size = 1,
		build_slices_per_frame = 4,
		background_build_slices_per_frame = 4,
		prefer_exposed_dirty_slices = true,
	}
	local ok, err = xpcall(function()
		voxelizer.Update(Vec3(0, 0, 0))
		local clipmap = voxelizer.GetClipmap(1)
		T(clipmap ~= nil)["=="](true)
		clipmap.has_valid_data = true
		voxelizer.MarkClipmapClean(1)
		clipmap.dirty_slice_masks.x[1] = true
		clipmap.dirty_slice_regions.x[1] = {
			full = false,
			rects = {
				{x = 0, y = 0, w = 1, h = 1},
			},
		}

		voxelizer.Update(Vec3(1.01, 0, 0))
		local dirty_range = voxelizer.GetClipmapDirtySliceRange(1, "x")
		T(dirty_range ~= nil)["=="](true)
		T(table.concat(dirty_range.slices, ","))["=="]("3,0")
	end, debug.traceback)

	restore_default_voxelizer(voxelizer)

	if not ok then error(err, 0) end
end)

T.Test3D("Graphics render3d voxelizer keeps valid full rebuild progress latched while camera target changes", function()
	local voxelizer = configure_test_voxelizer{
		base_resolution = 4,
		base_voxel_size = 1,
		build_slices_per_frame = 1,
		background_build_slices_per_frame = 1,
	}
	local ok, err = xpcall(function()
		voxelizer.Update(Vec3(0, 0, 0))
		local clipmap = voxelizer.GetClipmap(1)
		T(clipmap ~= nil)["=="](true)
		clipmap.has_valid_data = true
		voxelizer.MarkClipmapClean(1)

		voxelizer.Update(Vec3(4.01, 0, 0))
		clipmap = voxelizer.GetClipmap(1)
		T(clipmap.full_rebuild)["=="](true)
		T(clipmap.build_origin.x)["=="](4)
		T(clipmap.origin.x)["=="](4)

		local _, built_slices = voxelizer.ForEachDirtyAxisTarget(1, 3, function() end)
		T(built_slices)["=="](3)
		local dirty_before = clipmap.dirty_slabs.x + clipmap.dirty_slabs.y + clipmap.dirty_slabs.z
		T(dirty_before)["=="](9)
		T(clipmap.pending_dirty_slices ~= nil)["=="](true)

		voxelizer.Update(Vec3(5.01, 0, 0))
		clipmap = voxelizer.GetClipmap(1)
		T(clipmap.full_rebuild)["=="](true)
		T(clipmap.build_origin.x)["=="](4)
		local dirty_after = clipmap.dirty_slabs.x + clipmap.dirty_slabs.y + clipmap.dirty_slabs.z
		T(dirty_after)["=="](dirty_before)
		T(clipmap.pending_dirty_slices ~= nil)["=="](true)
	end, debug.traceback)

	restore_default_voxelizer(voxelizer)

	if not ok then error(err, 0) end
end)

T.Test3D("Graphics render3d voxelizer scroll copy translates occupied voxels into the build target", function(draw)
	local camera = render3d.GetCamera()
	camera:SetFOV(math.rad(90))
	camera:SetNearZ(0.1)
	camera:SetFarZ(100)
	camera:SetRotation(Quat():Identity())

	local voxelizer = configure_test_voxelizer{
		base_resolution = 16,
		base_voxel_size = 1,
		build_slices_per_frame = 64,
		background_build_slices_per_frame = 1,
	}
	local ok, err = xpcall(function()
		camera:SetPosition(Vec3(0, 0, 0))
		local box_center = voxelizer.VoxelToWorld(1, Vec3(11, 9, 7))
		local entity = make_box_entity(box_center, 0.2)
		local moved = false

		local inner_ok, inner_err = xpcall(function()
			voxelizer.Update(Vec3(0, 0, 0))
			local clipmap = wait_for_voxelizer_build(draw, voxelizer, 32)
			T(clipmap ~= nil)["=="](true)
			T(clipmap.dirty)["=="](false)

			camera:SetPosition(Vec3(1.01, 0, 0))
			voxelizer.Update(Vec3(1.01, 0, 0))
			draw()
			moved = true

			clipmap = voxelizer.GetClipmap(1)
			T(clipmap.build_scroll_ready)["=="](true)
			local build_targets = get_build_axis_targets(voxelizer, 1)
			local new_voxel = Vec3(10, 9, 7)
			local old_voxel = Vec3(11, 9, 7)
			local new_alpha = get_voxel_alpha_triplet(build_targets, new_voxel, clipmap.resolution)
			local old_alpha = get_voxel_alpha_triplet(build_targets, old_voxel, clipmap.resolution)

			if not voxel_is_occupied(build_targets, new_voxel, clipmap.resolution) then
				error(
					string.format(
						"expected scrolled build voxel (%d,%d,%d), got alpha=(x=%d y=%d z=%d)",
						new_voxel.x,
						new_voxel.y,
						new_voxel.z,
						new_alpha.x,
						new_alpha.y,
						new_alpha.z
					),
					0
				)
			end

			if voxel_is_occupied(build_targets, old_voxel, clipmap.resolution) then
				error(
					string.format(
						"old voxel (%d,%d,%d) remained occupied after scroll copy: alpha=(x=%d y=%d z=%d)",
						old_voxel.x,
						old_voxel.y,
						old_voxel.z,
						old_alpha.x,
						old_alpha.y,
						old_alpha.z
					),
					0
				)
			end
		end, debug.traceback)

		if entity and entity.IsValid and entity:IsValid() then entity:Remove() end
		if not inner_ok then error(inner_err, 0) end
	end, debug.traceback)

	restore_default_voxelizer(voxelizer)

	if not ok then error(err, 0) end
end)

T.Test3D("Graphics render3d voxelizer scroll copy preserves multiple interior voxels in the build target", function(draw)
	local camera = render3d.GetCamera()
	camera:SetFOV(math.rad(90))
	camera:SetNearZ(0.1)
	camera:SetFarZ(100)
	camera:SetRotation(Quat():Identity())

	local voxelizer = configure_test_voxelizer{
		base_resolution = 16,
		base_voxel_size = 1,
		build_slices_per_frame = 64,
		background_build_slices_per_frame = 1,
	}
	local ok, err = xpcall(function()
		camera:SetPosition(Vec3(0, 0, 0))
		local original_voxels = {
			Vec3(11, 9, 7),
			Vec3(8, 6, 10),
			Vec3(6, 11, 5),
		}
		local entities = {}

		for i, voxel in ipairs(original_voxels) do
			entities[i] = make_box_entity(voxelizer.VoxelToWorld(1, voxel), 0.2)
		end

		local inner_ok, inner_err = xpcall(function()
			voxelizer.Update(Vec3(0, 0, 0))
			local clipmap = wait_for_voxelizer_build(draw, voxelizer, 32)
			T(clipmap ~= nil)["=="](true)
			T(clipmap.dirty)["=="](false)

			camera:SetPosition(Vec3(1.01, 0, 0))
			voxelizer.Update(Vec3(1.01, 0, 0))
			draw()

			clipmap = voxelizer.GetClipmap(1)
			T(clipmap.build_scroll_ready)["=="](true)
			local build_targets = get_build_axis_targets(voxelizer, 1)

			for _, old_voxel in ipairs(original_voxels) do
				local new_voxel = Vec3(old_voxel.x - 1, old_voxel.y, old_voxel.z)

				if not voxel_is_occupied(build_targets, new_voxel, clipmap.resolution) then
					local alpha = get_voxel_alpha_triplet(build_targets, new_voxel, clipmap.resolution)
					error(
						string.format(
							"expected preserved scrolled voxel (%d,%d,%d), got alpha=(x=%d y=%d z=%d)",
							new_voxel.x,
							new_voxel.y,
							new_voxel.z,
							alpha.x,
							alpha.y,
							alpha.z
						),
						0
					)
				end

				if voxel_is_occupied(build_targets, old_voxel, clipmap.resolution) then
					local alpha = get_voxel_alpha_triplet(build_targets, old_voxel, clipmap.resolution)
					error(
						string.format(
							"old preserved voxel (%d,%d,%d) remained occupied after scroll copy: alpha=(x=%d y=%d z=%d)",
							old_voxel.x,
							old_voxel.y,
							old_voxel.z,
							alpha.x,
							alpha.y,
							alpha.z
						),
						0
					)
				end
			end
		end, debug.traceback)

		for _, entity in ipairs(entities) do
			if entity and entity.IsValid and entity:IsValid() then entity:Remove() end
		end

		if not inner_ok then error(inner_err, 0) end
	end, debug.traceback)

	restore_default_voxelizer(voxelizer)

	if not ok then error(err, 0) end
end)

T.Test3D("Graphics render3d voxelizer scroll copy preserves interior voxels across clipmaps", function(draw)
	local camera = render3d.GetCamera()
	camera:SetFOV(math.rad(90))
	camera:SetNearZ(0.1)
	camera:SetFarZ(100)
	camera:SetRotation(Quat():Identity())

	local voxelizer = configure_test_voxelizer{
		clipmap_count = 3,
		base_resolution = 16,
		base_voxel_size = 1,
		build_slices_per_frame = 64,
		background_build_slices_per_frame = 1,
	}
	local ok, err = xpcall(function()
		camera:SetPosition(Vec3(0, 0, 0))
		local seeded = {
			{clipmap_index = 1, voxel = Vec3(11, 9, 7), entity = nil},
			{clipmap_index = 2, voxel = Vec3(10, 8, 6), entity = nil},
			{clipmap_index = 3, voxel = Vec3(9, 7, 5), entity = nil},
		}

		for _, entry in ipairs(seeded) do
			entry.entity = make_box_entity(voxelizer.VoxelToWorld(entry.clipmap_index, entry.voxel), 0.2)
		end

		local inner_ok, inner_err = xpcall(function()
			voxelizer.Update(Vec3(0, 0, 0))
			for _ = 1, 32 do
				draw()
			end

			camera:SetPosition(Vec3(4.01, 0, 0))
			voxelizer.Update(Vec3(4.01, 0, 0))
			draw()

			for _, entry in ipairs(seeded) do
				local clipmap = voxelizer.GetClipmap(entry.clipmap_index)
				T(clipmap ~= nil)["=="](true)
				local build_targets = {
					x = voxelizer.GetClipmapLightingAxisTarget(entry.clipmap_index, "x"),
					y = voxelizer.GetClipmapLightingAxisTarget(entry.clipmap_index, "y"),
					z = voxelizer.GetClipmapLightingAxisTarget(entry.clipmap_index, "z"),
				}
				local delta_voxels = 4 / clipmap.voxel_size
				local shifted_voxel = Vec3(entry.voxel.x - delta_voxels, entry.voxel.y, entry.voxel.z)

				if not voxel_is_occupied(build_targets, shifted_voxel, clipmap.resolution) then
					local alpha = get_voxel_alpha_triplet(build_targets, shifted_voxel, clipmap.resolution)
					error(
						string.format(
							"clipmap %d expected shifted voxel (%d,%d,%d), got alpha=(x=%d y=%d z=%d)",
							entry.clipmap_index,
							shifted_voxel.x,
							shifted_voxel.y,
							shifted_voxel.z,
							alpha.x,
							alpha.y,
							alpha.z
						),
						0
					)
				end
				if voxel_is_occupied(build_targets, entry.voxel, clipmap.resolution) then
					local alpha = get_voxel_alpha_triplet(build_targets, entry.voxel, clipmap.resolution)
					error(
						string.format(
							"clipmap %d old voxel (%d,%d,%d) remained occupied after scroll copy: alpha=(x=%d y=%d z=%d)",
							entry.clipmap_index,
							entry.voxel.x,
							entry.voxel.y,
							entry.voxel.z,
							alpha.x,
							alpha.y,
							alpha.z
						),
						0
					)
				end
			end
		end, debug.traceback)

		for _, entry in ipairs(seeded) do
			local entity = entry.entity
			if entity and entity.IsValid and entity:IsValid() then entity:Remove() end
		end

		if not inner_ok then error(inner_err, 0) end
	end, debug.traceback)

	restore_default_voxelizer(voxelizer)

	if not ok then error(err, 0) end
end)

T.Test3D("Graphics render3d voxelizer preserves a scrolled flat slab in clipmap 1", function(draw)
	local camera = render3d.GetCamera()
	camera:SetFOV(math.rad(90))
	camera:SetNearZ(0.1)
	camera:SetFarZ(100)
	camera:SetRotation(Quat():Identity())

	local voxelizer = configure_test_voxelizer{
		clipmap_count = 1,
		base_resolution = 16,
		base_voxel_size = 1,
		build_slices_per_frame = 64,
		background_build_slices_per_frame = 1,
	}
	local ok, err = xpcall(function()
		camera:SetPosition(Vec3(0, 0, 0))
		local seeded = {
			Vec3(4, 8, 7),
			Vec3(5, 8, 7),
			Vec3(6, 8, 7),
			Vec3(7, 8, 7),
			Vec3(8, 8, 7),
			Vec3(9, 8, 7),
			Vec3(10, 8, 7),
			Vec3(11, 8, 7),
		}
		local entities = {}

		for i, voxel in ipairs(seeded) do
			entities[i] = make_box_entity(voxelizer.VoxelToWorld(1, voxel), 0.2)
		end

		local inner_ok, inner_err = xpcall(function()
			voxelizer.Update(Vec3(0, 0, 0))
			local clipmap = wait_for_voxelizer_build(draw, voxelizer, 32)
			T(clipmap ~= nil)["=="](true)
			T(clipmap.dirty)["=="](false)

			camera:SetPosition(Vec3(4.01, 0, 0))
			voxelizer.Update(Vec3(4.01, 0, 0))
			draw()

			clipmap = voxelizer.GetClipmap(1)
			local sampled_targets = {
				x = voxelizer.GetClipmapLightingAxisTarget(1, "x"),
				y = voxelizer.GetClipmapLightingAxisTarget(1, "y"),
				z = voxelizer.GetClipmapLightingAxisTarget(1, "z"),
			}

			for _, old_voxel in ipairs(seeded) do
				local shifted_voxel = Vec3(old_voxel.x - 4, old_voxel.y, old_voxel.z)

				if not voxel_is_occupied(sampled_targets, shifted_voxel, clipmap.resolution) then
					local alpha = get_voxel_alpha_triplet(sampled_targets, shifted_voxel, clipmap.resolution)
					error(
						string.format(
							"expected shifted slab voxel (%d,%d,%d), got alpha=(x=%d y=%d z=%d)",
							shifted_voxel.x,
							shifted_voxel.y,
							shifted_voxel.z,
							alpha.x,
							alpha.y,
							alpha.z
						),
						0
					)
				end
			end
		end, debug.traceback)

		for _, entity in ipairs(entities) do
			if entity and entity.IsValid and entity:IsValid() then entity:Remove() end
		end

		if not inner_ok then error(inner_err, 0) end
	end, debug.traceback)

	restore_default_voxelizer(voxelizer)

	if not ok then error(err, 0) end
end)

T.Test3D("Graphics render3d voxelizer preserves a scrolled flat patch in clipmap 1", function(draw)
	local camera = render3d.GetCamera()
	camera:SetFOV(math.rad(90))
	camera:SetNearZ(0.1)
	camera:SetFarZ(100)
	camera:SetRotation(Quat():Identity())

	local voxelizer = configure_test_voxelizer{
		clipmap_count = 1,
		base_resolution = 16,
		base_voxel_size = 1,
		build_slices_per_frame = 64,
		background_build_slices_per_frame = 1,
	}
	local ok, err = xpcall(function()
		camera:SetPosition(Vec3(0, 0, 0))
		local seeded = {}
		local entities = {}

		for x = 4, 11 do
			for z = 5, 9 do
				seeded[#seeded + 1] = Vec3(x, 8, z)
			end
		end

		for i, voxel in ipairs(seeded) do
			entities[i] = make_box_entity(voxelizer.VoxelToWorld(1, voxel), 0.2)
		end

		local inner_ok, inner_err = xpcall(function()
			voxelizer.Update(Vec3(0, 0, 0))
			local clipmap = wait_for_voxelizer_build(draw, voxelizer, 32)
			T(clipmap ~= nil)["=="](true)
			T(clipmap.dirty)["=="](false)

			camera:SetPosition(Vec3(4.01, 0, 0))
			voxelizer.Update(Vec3(4.01, 0, 0))
			draw()

			clipmap = voxelizer.GetClipmap(1)
			local sampled_targets = {
				x = voxelizer.GetClipmapLightingAxisTarget(1, "x"),
				y = voxelizer.GetClipmapLightingAxisTarget(1, "y"),
				z = voxelizer.GetClipmapLightingAxisTarget(1, "z"),
			}

			for _, old_voxel in ipairs(seeded) do
				local shifted_voxel = Vec3(old_voxel.x - 4, old_voxel.y, old_voxel.z)

				if not voxel_is_occupied(sampled_targets, shifted_voxel, clipmap.resolution) then
					local alpha = get_voxel_alpha_triplet(sampled_targets, shifted_voxel, clipmap.resolution)
					error(
						string.format(
							"expected shifted patch voxel (%d,%d,%d), got alpha=(x=%d y=%d z=%d)",
							shifted_voxel.x,
							shifted_voxel.y,
							shifted_voxel.z,
							alpha.x,
							alpha.y,
							alpha.z
						),
						0
					)
				end
			end
		end, debug.traceback)

		for _, entity in ipairs(entities) do
			if entity and entity.IsValid and entity:IsValid() then entity:Remove() end
		end

		if not inner_ok then error(inner_err, 0) end
	end, debug.traceback)

	restore_default_voxelizer(voxelizer)

	if not ok then error(err, 0) end
end)

T.Test3D("Graphics render3d voxelizer preserves a scrolled scaled flat slab in clipmap 1", function(draw)
	local camera = render3d.GetCamera()
	camera:SetFOV(math.rad(90))
	camera:SetNearZ(0.1)
	camera:SetFarZ(100)
	camera:SetRotation(Quat():Identity())

	local voxelizer = configure_test_voxelizer{
		clipmap_count = 1,
		base_resolution = 16,
		base_voxel_size = 1,
		build_slices_per_frame = 64,
		background_build_slices_per_frame = 1,
	}
	local ok, err = xpcall(function()
		camera:SetPosition(Vec3(0, 0, 0))
		local slab_center = voxelizer.VoxelToWorld(1, Vec3(8, 8, 7))
		local entity = make_box_entity(slab_center, 0.5, Vec3(8, 1, 5))

		local inner_ok, inner_err = xpcall(function()
			voxelizer.Update(Vec3(0, 0, 0))
			local clipmap = wait_for_voxelizer_build(draw, voxelizer, 32)
			T(clipmap ~= nil)["=="](true)
			T(clipmap.dirty)["=="](false)

			camera:SetPosition(Vec3(4.01, 0, 0))
			voxelizer.Update(Vec3(4.01, 0, 0))
			draw()

			clipmap = voxelizer.GetClipmap(1)
			local sampled_targets = {
				x = voxelizer.GetClipmapLightingAxisTarget(1, "x"),
				y = voxelizer.GetClipmapLightingAxisTarget(1, "y"),
				z = voxelizer.GetClipmapLightingAxisTarget(1, "z"),
			}

			for x = 1, 8 do
				for z = 5, 9 do
					local voxel = Vec3(x, 8, z)

					if not voxel_has_any_occupancy(sampled_targets, voxel, clipmap.resolution) then
						local alpha = get_voxel_alpha_triplet(sampled_targets, voxel, clipmap.resolution)
						error(
							string.format(
								"expected shifted scaled slab voxel (%d,%d,%d), got alpha=(x=%d y=%d z=%d)",
								voxel.x,
								voxel.y,
								voxel.z,
								alpha.x,
								alpha.y,
								alpha.z
							),
							0
						)
					end
				end
			end
		end, debug.traceback)

		if entity and entity.IsValid and entity:IsValid() then entity:Remove() end

		if not inner_ok then error(inner_err, 0) end
	end, debug.traceback)

	restore_default_voxelizer(voxelizer)

	if not ok then error(err, 0) end
end)

T.Test3D("Graphics render3d voxelizer preserves a scaled flat slab across repeated fast scrolls", function(draw)
	local camera = render3d.GetCamera()
	camera:SetFOV(math.rad(90))
	camera:SetNearZ(0.1)
	camera:SetFarZ(100)
	camera:SetRotation(Quat():Identity())

	local voxelizer = configure_test_voxelizer{
		clipmap_count = 1,
		base_resolution = 16,
		base_voxel_size = 1,
		build_slices_per_frame = 64,
		background_build_slices_per_frame = 1,
	}
	local ok, err = xpcall(function()
		camera:SetPosition(Vec3(0, 0, 0))
		local slab_center = voxelizer.VoxelToWorld(1, Vec3(8, 8, 7))
		local entity = make_box_entity(slab_center, 0.5, Vec3(8, 1, 5))

		local inner_ok, inner_err = xpcall(function()
			local positions = {
				Vec3(0, 0, 0),
				Vec3(4.01, 0, 0),
				Vec3(8.01, 0, 0),
				Vec3(12.01, 0, 0),
			}

			for step, camera_position in ipairs(positions) do
				camera:SetPosition(camera_position)
				voxelizer.Update(camera_position)

				if step == 1 then
					local clipmap = wait_for_voxelizer_build(draw, voxelizer, 32)
					T(clipmap ~= nil)["=="](true)
					T(clipmap.dirty)["=="](false)
				else
					draw()
					local clipmap = voxelizer.GetClipmap(1)
					local sampled_targets = {
						x = voxelizer.GetClipmapLightingAxisTarget(1, "x"),
						y = voxelizer.GetClipmapLightingAxisTarget(1, "y"),
						z = voxelizer.GetClipmapLightingAxisTarget(1, "z"),
					}

					for x = 1, 8 do
						for z = 5, 9 do
							local voxel = Vec3(x - (step - 2) * 4, 8, z)

							if voxel.x >= 0 and voxel.x < clipmap.resolution then
								if not voxel_has_any_occupancy(sampled_targets, voxel, clipmap.resolution) then
									local alpha = get_voxel_alpha_triplet(sampled_targets, voxel, clipmap.resolution)
									error(
										string.format(
											"expected repeated-scroll slab voxel step=%d (%d,%d,%d), got alpha=(x=%d y=%d z=%d)",
											step,
											voxel.x,
											voxel.y,
											voxel.z,
											alpha.x,
											alpha.y,
											alpha.z
										),
										0
									)
								end
							end
						end
					end
				end
			end
		end, debug.traceback)

		if entity and entity.IsValid and entity:IsValid() then entity:Remove() end

		if not inner_ok then error(inner_err, 0) end
	end, debug.traceback)

	restore_default_voxelizer(voxelizer)

	if not ok then error(err, 0) end
end)

T.Test3D("Graphics render3d voxelizer completion commits before follow-up reschedule", function()
	local voxelizer = configure_test_voxelizer{
		base_resolution = 4,
		base_voxel_size = 1,
		build_slices_per_frame = 1,
		background_build_slices_per_frame = 1,
	}
	local ok, err = xpcall(function()
		voxelizer.Update(Vec3(0, 0, 0))
		local clipmap = voxelizer.GetClipmap(1)
		T(clipmap ~= nil)["=="](true)
		clipmap.has_valid_data = true
		voxelizer.MarkClipmapClean(1)

		voxelizer.Update(Vec3(1.01, 0, 0))
		clipmap = voxelizer.GetClipmap(1)
		T(clipmap.pending_scroll.delta.x)["=="](1)
		T(clipmap.build_origin.x)["=="](1)

		voxelizer.last_camera_position = Vec3(2.01, 0, 0)
		voxelizer.MarkClipmapBuilt(1, 1, 1)
		clipmap = voxelizer.GetClipmap(1)

		T(clipmap.origin.x)["=="](1)
		T(clipmap.build_origin.x)["=="](2)
		T(clipmap.pending_scroll ~= nil)["=="](true)
		T(clipmap.pending_scroll.delta.x)["=="](1)
		T(clipmap.clear_dirty_slices)["=="](false)
		local y_repair = voxelizer.GetClipmapDirtySliceRepair(1, "y", 0)
		T(y_repair ~= nil)["=="](true)
		T(y_repair.full)["=="](false)
	end, debug.traceback)

	restore_default_voxelizer(voxelizer)

	if not ok then error(err, 0) end
end)