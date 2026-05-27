local T = import("test/environment.lua")
local ffi = require("ffi")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Material = import("goluwa/render3d/material.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Color = import("goluwa/structs/color.lua")
local Entity = import("goluwa/ecs/entity.lua")

local function attach_visual(entity, polygon3d, material)
	entity:AddComponent("visual")
	local primitive = Entity.New{
		Name = (entity:GetName() or "voxelizer") .. "_primitive",
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

local function make_box_entity(position, size)
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
	attach_visual(entity, polygon3d, material)
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
	return render3d.GetSceneVoxelizer().ResetState{
		enabled = true,
		clipmap_count = config.clipmap_count or 1,
		base_resolution = config.base_resolution or 16,
		base_voxel_size = config.base_voxel_size or 1,
		clipmap_snap_voxel_stride = config.clipmap_snap_voxel_stride or 1,
		build_slices_per_frame = config.build_slices_per_frame or 64,
		background_build_slices_per_frame = config.background_build_slices_per_frame or 64,
	}
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
	T(voxel_is_occupied(axis_targets, occupied_voxel, clipmap.resolution))["=="](true)

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

T.Test3D("Graphics render3d voxelizer does not swap in a stale background build after the camera moves farther", function(draw)
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
		local clipmap = wait_for_voxelizer_build(draw, voxelizer, 16)
		T(clipmap ~= nil)["=="](true)
		T(clipmap.dirty)["=="](false)
		T(clipmap.origin.x)["=="](0)

		camera:SetPosition(Vec3(1.01, 0, 0))
		voxelizer.Update(Vec3(1.01, 0, 0))
		clipmap = voxelizer.GetClipmap(1)
		T(clipmap.building_into_scroll)["=="](true)
		T(clipmap.build_origin.x)["=="](1)
		T(clipmap.origin.x)["=="](0)

		camera:SetPosition(Vec3(5.01, 0, 0))
		voxelizer.Update(Vec3(5.01, 0, 0))
		clipmap = voxelizer.GetClipmap(1)
		T(clipmap.build_origin.x)["=="](5)
		T(clipmap.origin.x)["=="](0)

		draw_voxelizer_frames(draw, 12)
		clipmap = voxelizer.GetClipmap(1)
		T(clipmap.build_origin.x)["=="](5)
		T(clipmap.origin.x == 1)["=="](false)

		draw_voxelizer_frames(draw, 12)
		clipmap = voxelizer.GetClipmap(1)
		T(clipmap.dirty)["=="](false)
		T(clipmap.origin.x)["=="](5)
	end, debug.traceback)

	restore_default_voxelizer(voxelizer)

	if not ok then error(err, 0) end
end)