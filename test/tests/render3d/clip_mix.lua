local T = import("test/environment.lua")
local Skeleton = import("goluwa/render3d/skeleton.lua")
local ffi = require("ffi")

local function join(...)
	return table.concat({...}, ",")
end

local function create_skeleton()
	local bind = ffi.new("float[?]", 5 * 7)

	for i = 0, 4 do
		bind[i * 7 + 6] = 1
	end

	return Skeleton.New{
		BoneNames = {"pelvis", "spine", "arm", "thigh", "calf"},
		Parents = {-1, 0, 1, 0, 3},
		BindLocal = bind,
		InverseBind = ffi.new("float[?]", 5 * 12),
	}
end

local function add_constant_clip(skeleton, name, x, duration, ground_speed)
	skeleton:AddClip{
		Name = name,
		Duration = duration,
		Loop = true,
		GetGroundSpeed = function()
			return ground_speed
		end,
		Sample = function(clip, cycle, params, out)
			for i = 0, 4 do
				out[i * 7], out[i * 7 + 1], out[i * 7 + 2] = x, 0, 0
				out[i * 7 + 3], out[i * 7 + 4], out[i * 7 + 5], out[i * 7 + 6] = 0, 0, 0, 1
			end
		end,
	}
end

T.Test("a bone mask covers the subtrees of its roots", function()
	local skeleton = create_skeleton()
	local mask = skeleton:CreateBoneMask({"spine"}, 1)
	T(join(mask[0], mask[1], mask[2], mask[3], mask[4]))["=="]("0,1,1,0,0")
	mask = skeleton:CreateBoneMask({"spine", "calf"}, 0.5)
	T(join(mask[0], mask[1], mask[2], mask[3], mask[4]))["=="]("0,0.5,0.5,0,0.5")
end)

T.Test("a mix clip takes each bone from the layer that covers it", function()
	local skeleton = create_skeleton()
	add_constant_clip(skeleton, "lower", 1, 1.5, 3)
	add_constant_clip(skeleton, "upper", 2, 0.5, 7)
	skeleton:AddMixClip{
		Name = "mixed",
		Layers = {{Clip = "lower"}, {Clip = "upper", Bones = {"spine"}}},
	}
	local mixed = skeleton.ClipsByName.mixed
	T(mixed.Duration)["=="](1.5)
	T(mixed.Loop)["=="](true)
	T(mixed:GetGroundSpeed({}))["=="](3)
	local pose = skeleton:CreatePose()
	mixed:Sample(0.3, {}, pose)
	T(join(pose[0], pose[7], pose[14], pose[21], pose[28]))["=="]("1,2,2,1,1")
	T(pose[6])["=="](1)
	skeleton:AddMixClip{
		Name = "half",
		GroundSpeedLayer = 2,
		Layers = {{Clip = "lower"}, {Clip = "upper", Bones = {"spine"}, Weight = 0.5}},
	}
	skeleton.ClipsByName.half:Sample(0, {}, pose)
	T(join(pose[0], pose[7], pose[14], pose[21]))["=="]("1,1.5,1.5,1")
	T(skeleton.ClipsByName.half:GetGroundSpeed({}))["=="](7)
	T(
		pcall(
			skeleton.AddMixClip,
			skeleton,
			{Name = "bad", Layers = {{Clip = "lower"}, {Clip = "missing"}}}
		)
	)["=="](false)
end)

T.Test("a masked blend keeps rotations normalized and takes the short way round", function()
	local skeleton = create_skeleton()
	local a, b, out = skeleton:CreatePose(), skeleton:CreatePose(), skeleton:CreatePose()

	for i = 0, 4 do
		a[i * 7 + 6] = 1
		b[i * 7 + 6] = -1
	end

	skeleton:BlendPosesMasked(a, b, ffi.new("float[5]", {0, 0.5, 1, 0, 0}), out)
	T(out[6])["=="](1)
	T(math.abs(out[13]))["=="](1)
	T(out[20])["=="](-1)
end)
