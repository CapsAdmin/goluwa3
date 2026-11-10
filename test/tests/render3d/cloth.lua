local T = import("test/environment.lua")
local ffi = require("ffi")
local Skeleton = import("goluwa/render3d/skeleton.lua")
local Cloth = import("goluwa/render3d/cloth.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local NODES = 4
local SPACING = 0.1

local function create_cloth()
	local bones = NODES + 1
	local bind = ffi.new("float[?]", bones * Skeleton.PoseSize)
	local inverse = ffi.new("float[?]", bones * Skeleton.MatrixSize)
	local parents = {-1}
	local names = {"root"}

	for i = 0, bones - 1 do
		bind[i * 7 + 6] = 1
		inverse[i * 12], inverse[i * 12 + 5], inverse[i * 12 + 10] = 1, 1, 1

		if i > 0 then
			parents[i + 1] = 0
			names[i + 1] = "node" .. i
			bind[i * 7 + 1] = -SPACING * (i - 1)
			inverse[i * 12 + 7] = SPACING * (i - 1)
		end
	end

	local skeleton = Skeleton.New{
		BoneNames = names,
		Parents = parents,
		BindLocal = bind,
		InverseBind = inverse,
	}
	local node_bone = ffi.new("int32_t[?]", NODES, {1, 2, 3, 4})
	local inv_mass = ffi.new("float[?]", NODES, {0, 1, 1, 1})
	local attraction = ffi.new("float[?]", NODES)
	local gravity = ffi.new("float[?]", NODES, {9.8, 9.8, 9.8, 9.8})
	local target_start = ffi.new("int32_t[?]", NODES + 1, {0, 1, 2, 3, 4})
	local target_bone = ffi.new("int32_t[?]", NODES, {0, 0, 0, 0})
	local target_offset = ffi.new("float[?]", NODES * 3)
	local target_alpha = ffi.new("float[?]", NODES, {1, 1, 1, 1})

	for i = 0, NODES - 1 do
		target_offset[i * 3 + 1] = -SPACING * i
	end

	local rod_nodes = ffi.new("int32_t[?]", (NODES - 1) * 2)
	local rod_limits = ffi.new("float[?]", (NODES - 1) * 2)

	for i = 0, NODES - 2 do
		rod_nodes[i * 2], rod_nodes[i * 2 + 1] = i, i + 1
		rod_limits[i * 2], rod_limits[i * 2 + 1] = SPACING, SPACING
	end

	skeleton.Cloth = {
		count = NODES,
		rod_count = NODES - 1,
		node_bone = node_bone,
		inv_mass = inv_mass,
		attraction = attraction,
		gravity = gravity,
		target_start = target_start,
		target_bone = target_bone,
		target_offset = target_offset,
		target_alpha = target_alpha,
		rod_nodes = rod_nodes,
		rod_limits = rod_limits,
	}
	return skeleton
end

local function create_rig(skeleton)
	local rig = {
		world = skeleton:CreateMatrices(),
		matrices = skeleton:CreateMatrices(),
		pose = skeleton:NewPose(),
	}
	skeleton:ComputeSkinMatrices(rig.pose.data, rig.matrices, rig.world)
	return rig
end

local function node_position(rig, bone)
	return rig.world[bone * 12 + 3],
	rig.world[bone * 12 + 7],
	rig.world[bone * 12 + 11]
end

T.Test("cloth nodes hang from their pinned node and keep their rod lengths", function()
	local skeleton = create_cloth()
	local rig = create_rig(skeleton)
	local cloth = Cloth.New(skeleton)
	local matrix = Matrix44()

	for _ = 1, 120 do
		cloth:Advance(1 / 60, matrix)
		skeleton:ComputeSkinMatrices(rig.pose.data, rig.matrices, rig.world)
		cloth:Apply(rig)
	end

	local x1, y1 = node_position(rig, 1)
	T(x1)["=="](0)
	T(y1)["=="](0)
	local previous_y = y1

	for bone = 2, NODES do
		local x, y, z = node_position(rig, bone)
		local px, py, pz = node_position(rig, bone - 1)
		local length = math.sqrt((x - px) ^ 2 + (y - py) ^ 2 + (z - pz) ^ 2)
		T(math.abs(length - SPACING) < 5e-3)["=="](true)
		T(y < previous_y)["=="](true)
		previous_y = y
	end
end)

T.Test("cloth trails behind a moving entity", function()
	local skeleton = create_cloth()
	local rig = create_rig(skeleton)
	local cloth = Cloth.New(skeleton)
	local matrix = Matrix44()
	local x = 0

	for _ = 1, 60 do
		x = x + 0.05
		matrix.m30 = x
		cloth:Advance(1 / 60, matrix)
		skeleton:ComputeSkinMatrices(rig.pose.data, rig.matrices, rig.world)
		cloth:Apply(rig)
	end

	T(select(1, node_position(rig, NODES)) < -0.01)["=="](true)
end)
