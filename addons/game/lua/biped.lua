local Vec3 = import("goluwa/structs/vec3.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local UNIT = import("goluwa/source_engine/units.lua").meters
local eye_pose = import("lua/eye_pose.lua")
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
biped.SourceBones = {
	body = "ValveBiped.Bip01_Pelvis",
	waist = "ValveBiped.Bip01_Spine",
	spine = "ValveBiped.Bip01_Spine1",
	chest = "ValveBiped.Bip01_Spine2",
	back = "ValveBiped.Bip01_Spine4",
	neck = "ValveBiped.Bip01_Neck1",
	head = "ValveBiped.Bip01_Head1",
	clavicle_r = "ValveBiped.Bip01_R_Clavicle",
	upperarm_r = "ValveBiped.Bip01_R_UpperArm",
	forearm_r = "ValveBiped.Bip01_R_Forearm",
	hand_r = "ValveBiped.Bip01_R_Hand",
	clavicle_l = "ValveBiped.Bip01_L_Clavicle",
	upperarm_l = "ValveBiped.Bip01_L_UpperArm",
	forearm_l = "ValveBiped.Bip01_L_Forearm",
	hand_l = "ValveBiped.Bip01_L_Hand",
	thigh_r = "ValveBiped.Bip01_R_Thigh",
	calf_r = "ValveBiped.Bip01_R_Calf",
	foot_r = "ValveBiped.Bip01_R_Foot",
	thigh_l = "ValveBiped.Bip01_L_Thigh",
	calf_l = "ValveBiped.Bip01_L_Calf",
	foot_l = "ValveBiped.Bip01_L_Foot",
}
local IDENTITY = Matrix44():Identity()

function biped.HasBone(rig, name)
	local source = biped.SourceBones[name]
	return source ~= nil and rig.bone_indices[source:lower()] ~= nil
end

function biped.ReadBones(rig, bones)
	for _, entry in ipairs(biped.Bones) do
		local name, parent = entry[1], entry[2]

		if biped.HasBone(rig, name) then
			bones[name] = rig:GetBone(biped.SourceBones[name])
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
	center = {Bone = "spine"},
	feet = {Bone = "root"},
}
biped.SocketProfiles.source_humanoid = {
	grip_r = {Bone = "hand_r"},
	grip_l = {Bone = "hand_l"},
	eye = {Bone = "head"},
	head = {Bone = "head"},
	center = {Bone = "spine"},
	feet = {Bone = "root"},
}

if RENDER_3D then
	import("goluwa/entities/components/armature.lua").RegisterSkeleton(biped.SkeletonName, biped.Bones)
end

return biped
