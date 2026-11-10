local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local UNIT = import("goluwa/source_engine/units.lua").meters
local eye_pose = import("lua/eye_pose.lua")
local rig_profiles = import("lua/rig_profiles.lua")
local biped = {}
biped.SkeletonName = "biped"
biped.Height = 72 * UNIT
biped.CrouchScale = 0.5
biped.Bones = {
	{"root"},
	{"body", "root"},
	{"waist", "body"},
	{"spine", "waist"},
	{"chest", "spine"},
	{"back", "chest"},
	{"neck", "back"},
	{"head", "neck"},
	{"clavicle_r", "back"},
	{"upperarm_r", "clavicle_r"},
	{"forearm_r", "upperarm_r"},
	{"hand_r", "forearm_r"},
	{"clavicle_l", "back"},
	{"upperarm_l", "clavicle_l"},
	{"forearm_l", "upperarm_l"},
	{"hand_l", "forearm_l"},
	{"thigh_r", "body"},
	{"calf_r", "thigh_r"},
	{"foot_r", "calf_r"},
	{"thigh_l", "body"},
	{"calf_l", "thigh_l"},
	{"foot_l", "calf_l"},
}
-- measured from the idle pose of the ValveBiped models (meters, feet at the origin, right is +x)
local rest_meters = {
	root = {0, 0, 0},
	body = {0, 0.722, 0},
	waist = {0, 0.79, 0},
	spine = {0, 0.863, 0},
	chest = {0, 0.93, 0},
	back = {0, 1.103, 0},
	neck = {0, 1.16, 0},
	head = {0, 1.218, 0},
	clavicle_r = {0.04, 1.134, 0},
	upperarm_r = {0.155, 1.097, 0},
	forearm_r = {0.2, 0.877, 0},
	hand_r = {0.213, 0.678, 0},
	thigh_r = {0.081, 0.722, 0},
	calf_r = {0.082, 0.384, 0},
	foot_r = {0.062, 0.085, 0},
}
biped.Rest = {}

for name, position in pairs(rest_meters) do
	biped.Rest[name] = {
		position[1] / biped.Height,
		position[2] / biped.Height,
		position[3] / biped.Height,
	}

	if name:sub(-2) == "_r" then
		biped.Rest[name:sub(1, -3) .. "_l"] = {
			-position[1] / biped.Height,
			position[2] / biped.Height,
			position[3] / biped.Height,
		}
	end
end

local humanoid = {
	Parts = {
		{
			Name = "pelvis",
			From = "body",
			To = "spine",
			Radius = 0.17,
			Mass = 8,
			Multiplier = 1,
			Role = "torso",
			Bone = "body",
		},
		{
			Name = "torso",
			From = "spine",
			To = "chest",
			ToOffset = Vec3(0, 0.1, 0),
			Radius = 0.19,
			Mass = 14,
			Multiplier = 1,
			Role = "torso",
			Bone = "spine",
		},
		{
			Name = "head",
			From = "head",
			To = "head",
			ToOffset = Vec3(0, 0.08, 0),
			Radius = 0.13,
			Mass = 4,
			Multiplier = 2.5,
			Role = "head",
			Bone = "head",
		},
	},
}
local parts = humanoid.Parts

for _, side in ipairs{"r", "l"} do
	table.insert(
		parts,
		{
			Name = "upperarm_" .. side,
			From = "upperarm_" .. side,
			To = "forearm_" .. side,
			Radius = 0.065,
			Mass = 2,
			Multiplier = 0.7,
			Role = "limb",
			Bone = "upperarm_" .. side,
		}
	)
	table.insert(
		parts,
		{
			Name = "forearm_" .. side,
			From = "forearm_" .. side,
			To = "hand_" .. side,
			Radius = 0.055,
			Mass = 1.5,
			Multiplier = 0.7,
			Role = "limb",
			Bone = "forearm_" .. side,
		}
	)
	table.insert(
		parts,
		{
			Name = "thigh_" .. side,
			From = "thigh_" .. side,
			To = "calf_" .. side,
			Radius = 0.095,
			Mass = 5,
			Multiplier = 0.7,
			Role = "limb",
			Bone = "thigh_" .. side,
		}
	)
	table.insert(
		parts,
		{
			Name = "calf_" .. side,
			From = "calf_" .. side,
			To = "foot_" .. side,
			Radius = 0.075,
			Mass = 3,
			Multiplier = 0.6,
			Role = "limb",
			Bone = "calf_" .. side,
		}
	)
end

humanoid.Joints = {
	{Parent = "pelvis", Child = "torso", Anchor = "spine", Twist = 0.4, Swing = 0.35},
	{Parent = "torso", Child = "head", Anchor = "neck", Twist = 0.8, Swing = 0.5},
}

for _, side in ipairs{"r", "l"} do
	table.insert(
		humanoid.Joints,
		{
			Parent = "torso",
			Child = "upperarm_" .. side,
			Anchor = "upperarm_" .. side,
			Twist = 1,
			Swing = 1.5,
		}
	)
	table.insert(
		humanoid.Joints,
		{
			Parent = "upperarm_" .. side,
			Child = "forearm_" .. side,
			Anchor = "forearm_" .. side,
			Hinge = {0, 2.4},
		}
	)
	table.insert(
		humanoid.Joints,
		{
			Parent = "pelvis",
			Child = "thigh_" .. side,
			Anchor = "thigh_" .. side,
			Twist = 0.4,
			Swing = 1,
		}
	)
	table.insert(
		humanoid.Joints,
		{
			Parent = "thigh_" .. side,
			Child = "calf_" .. side,
			Anchor = "calf_" .. side,
			Hinge = {-2.4, 0},
		}
	)
end

humanoid.Hits = {
	pelvis = {Amount = 0.6, Hold = 0.1, Recover = 0.3, Impulse = 0.5},
	torso = {Amount = 0.6, Hold = 0.1, Recover = 0.3, Impulse = 0.5},
	head = {Amount = 0.6, Hold = 0.1, Recover = 0.3, Impulse = 0.5},
}
local eye_joints = {}
local eye_parts = {
	{
		Name = "head",
		From = "neck",
		To = "neck",
		ToOffset = Vec3(0, 0.01, 0),
		Radius = eye_pose.EyeRadius,
		Mass = 6,
		Multiplier = 2.5,
		Role = "head",
		Bone = "neck",
	},
}

for _, side in ipairs{"r", "l"} do
	table.insert(
		eye_parts,
		{
			Name = "upperarm_" .. side,
			From = "upperarm_" .. side,
			To = "forearm_" .. side,
			Radius = 0.05,
			Mass = 2,
			Multiplier = 0.7,
			Role = "limb",
			Bone = "upperarm_" .. side,
		}
	)
	table.insert(
		eye_parts,
		{
			Name = "forearm_" .. side,
			From = "forearm_" .. side,
			To = "hand_" .. side,
			Radius = 0.045,
			Mass = 1.5,
			Multiplier = 0.7,
			Role = "limb",
			Bone = "forearm_" .. side,
		}
	)
	table.insert(
		eye_parts,
		{
			Name = "thigh_" .. side,
			From = "thigh_" .. side,
			To = "calf_" .. side,
			Radius = 0.06,
			Mass = 4,
			Multiplier = 0.7,
			Role = "limb",
			Bone = "thigh_" .. side,
		}
	)
	table.insert(
		eye_parts,
		{
			Name = "calf_" .. side,
			From = "calf_" .. side,
			To = "foot_" .. side,
			Radius = 0.05,
			Mass = 3,
			Multiplier = 0.6,
			Role = "limb",
			Bone = "calf_" .. side,
		}
	)
	table.insert(
		eye_joints,
		{
			Parent = "head",
			Child = "upperarm_" .. side,
			Anchor = "upperarm_" .. side,
			Twist = 1,
			Swing = 1.5,
		}
	)
	table.insert(
		eye_joints,
		{
			Parent = "upperarm_" .. side,
			Child = "forearm_" .. side,
			Anchor = "forearm_" .. side,
			Hinge = {0, 2.4},
		}
	)
	table.insert(
		eye_joints,
		{
			Parent = "head",
			Child = "thigh_" .. side,
			Anchor = "thigh_" .. side,
			Twist = 0.4,
			Swing = 1,
		}
	)
	table.insert(
		eye_joints,
		{
			Parent = "thigh_" .. side,
			Child = "calf_" .. side,
			Anchor = "calf_" .. side,
			Hinge = {-2.4, 0},
		}
	)
end

local limb_hit = {Amount = 0.9, Hold = 1, Recover = 0.4, Impulse = 1}
local eye_hits = {head = {Amount = 0.6, Hold = 0.1, Recover = 0.3, Impulse = 0.5}}

for _, side in ipairs{"r", "l"} do
	for _, name in ipairs{"upperarm_", "forearm_", "thigh_", "calf_"} do
		humanoid.Hits[name .. side] = limb_hit
		eye_hits[name .. side] = limb_hit
	end
end

biped.Profiles = {
	humanoid = humanoid,
	eye = {
		Parts = eye_parts,
		Joints = eye_joints,
		Hits = eye_hits,
		Attach = {
			body = "neck",
			waist = "neck",
			spine = "neck",
			chest = "neck",
			back = "neck",
			clavicle_r = "neck",
			clavicle_l = "neck",
		},
	},
}
biped.SourceBones = rig_profiles.ValveBiped.Bones
local IDENTITY = Matrix44():Identity()

local function apply_fix(matrix, fix)
	local r00, r01, r02 = matrix.m00, matrix.m10, matrix.m20
	local r10, r11, r12 = matrix.m01, matrix.m11, matrix.m21
	local r20, r21, r22 = matrix.m02, matrix.m12, matrix.m22
	local f1, f2, f3, f4, f5, f6, f7, f8, f9 = fix[1], fix[2], fix[3], fix[4], fix[5], fix[6], fix[7], fix[8], fix[9]
	matrix.m00 = r00 * f1 + r01 * f4 + r02 * f7
	matrix.m10 = r00 * f2 + r01 * f5 + r02 * f8
	matrix.m20 = r00 * f3 + r01 * f6 + r02 * f9
	matrix.m01 = r10 * f1 + r11 * f4 + r12 * f7
	matrix.m11 = r10 * f2 + r11 * f5 + r12 * f8
	matrix.m21 = r10 * f3 + r11 * f6 + r12 * f9
	matrix.m02 = r20 * f1 + r21 * f4 + r22 * f7
	matrix.m12 = r20 * f2 + r21 * f5 + r22 * f8
	matrix.m22 = r20 * f3 + r21 * f6 + r22 * f9
end

local scratch = Matrix44():Identity()
local MATRIX_FIELDS = {
	"m00",
	"m01",
	"m02",
	"m03",
	"m10",
	"m11",
	"m12",
	"m13",
	"m20",
	"m21",
	"m22",
	"m23",
	"m30",
	"m31",
	"m32",
	"m33",
}

function biped.GetProfile(rig)
	return rig_profiles.Get(rig.skeleton)
end

function biped.GetBoneName(rig, name)
	return rig_profiles.Get(rig.skeleton).Bones[name]
end

function biped.HasBone(rig, name)
	local source = rig_profiles.Get(rig.skeleton).Bones[name]
	return source ~= nil and rig.bone_indices[source:lower()] ~= nil
end

-- the bone in the canonical frame of its biped name (what the pose code works with), not the rig's own axes
function biped.GetBone(rig, name, out)
	local profile = rig_profiles.Get(rig.skeleton)
	local matrix = rig:GetBone(profile.Bones[name], out)
	local frame = profile.Frames[name]

	if frame then apply_fix(matrix, frame.fix) end

	return matrix
end

-- turns a matrix in the canonical frame of a biped bone into the rig's frame, in place
function biped.ToRigFrame(rig, name, matrix)
	local frame = rig_profiles.Get(rig.skeleton).Frames[name]

	if frame then apply_fix(matrix, frame.unfix) end

	return matrix
end

function biped.WriteBone(rig, name, matrix)
	local profile = rig_profiles.Get(rig.skeleton)
	local frame = profile.Frames[name]

	if frame then
		for _, field in ipairs(MATRIX_FIELDS) do
			scratch[field] = matrix[field]
		end

		apply_fix(scratch, frame.unfix)
		matrix = scratch
	end

	rig:SetBone(profile.Bones[name], matrix, "model")
end

function biped.ClearBone(rig, name)
	if biped.HasBone(rig, name) then
		rig:ClearBone(rig_profiles.Get(rig.skeleton).Bones[name])
	end
end

function biped.ReadBones(rig, bones)
	for _, entry in ipairs(biped.Bones) do
		local name, parent = entry[1], entry[2]

		if biped.HasBone(rig, name) then
			bones[name] = biped.GetBone(rig, name)
		elseif parent then
			bones[name] = IDENTITY:GetMultiplied(bones[parent])
		end
	end
end

biped.SocketProfiles = {}
biped.SocketProfiles.biped = {
	grip_r = {Bone = "hand_r"},
	grip_l = {Bone = "hand_l"},
	eye = {Bone = "head"},
	head = {Bone = "head"},
	mouth = {Bone = "head"},
	center = {Bone = "spine"},
	feet = {Bone = "root"},
	chest = {Bone = "chest", Offset = Vec3(0, -0.6, -0.8) * (eye_pose.EyeRadius + 0.02)},
	back = {Bone = "chest", Offset = Vec3(0, -0.6, 0.8) * (eye_pose.EyeRadius + 0.02)},
}
biped.SocketProfiles.source_humanoid = {
	grip_r = {Bone = "hand_r"},
	grip_l = {Bone = "hand_l"},
	eye = {Bone = "head"},
	head = {Bone = "head"},
	-- ValveBiped Head1 points x forward, y right and z down, with x 14 degrees below where the face looks
	mouth = {
		Bone = "head",
		Offset = Vec3(0.09, 0, 0),
		Rotation = Quat(-0.4353, -0.4353, 0.5572, 0.5572),
	},
	center = {Bone = "spine"},
	feet = {Bone = "root"},
	-- ValveBiped Spine2 points x back, y left and z down, the socket faces forward with y up
	chest = {
		Bone = "chest",
		Offset = Vec3(-0.17, 0, -0.1),
		Rotation = Quat(-0.5, 0.5, -0.5, 0.5),
	},
	back = {Bone = "chest"},
}

function biped.GetCreatureSockets(height)
	local top = Vec3(0, height, 0)
	return {
		grip_r = {Bone = "root", Offset = top + Vec3(height * 0.3, 0, 0)},
		grip_l = {Bone = "root", Offset = top + Vec3(-height * 0.3, 0, 0)},
		eye = {Bone = "root", Offset = top},
		head = {Bone = "root", Offset = top},
		mouth = {Bone = "root", Offset = top},
		center = {Bone = "root", Offset = Vec3(0, height * 0.5, 0)},
		feet = {Bone = "root"},
		chest = {Bone = "root", Offset = Vec3(0, height * 0.6, 0)},
		back = {Bone = "root", Offset = Vec3(0, height * 0.6, 0)},
	}
end

if RENDER_3D then
	import("goluwa/entities/components/armature.lua").RegisterSkeleton(biped.SkeletonName, biped.Bones)
end

return biped
