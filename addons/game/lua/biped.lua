local Vec3 = import("goluwa/structs/vec3.lua")
local UNIT = import("goluwa/source_engine/units.lua").meters
local biped = {}
biped.SkeletonName = "biped"
biped.Height = 72 * UNIT
biped.CrouchScale = 0.5
biped.Bones = {
	{"root"},
	{"body", "root"},
	{"spine", "body"},
	{"chest", "spine"},
	{"neck", "chest"},
	{"head", "neck"},
	{"clavicle_r", "chest"},
	{"upperarm_r", "clavicle_r"},
	{"forearm_r", "upperarm_r"},
	{"hand_r", "forearm_r"},
	{"clavicle_l", "chest"},
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
	spine = {0, 0.863, 0},
	chest = {0, 0.93, 0},
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
	biped.Rest[name] = {position[1] / biped.Height, position[2] / biped.Height, position[3] / biped.Height}

	if name:sub(-2) == "_r" then
		biped.Rest[name:sub(1, -3) .. "_l"] = {-position[1] / biped.Height, position[2] / biped.Height, position[3] / biped.Height}
	end
end

biped.Parts = {
	{Name = "pelvis", From = "body", To = "spine", Radius = 0.17, Mass = 8, Multiplier = 1, Bone = "body"},
	{Name = "torso", From = "spine", To = "chest", ToOffset = Vec3(0, 0.1, 0), Radius = 0.19, Mass = 14, Multiplier = 1, Bone = "spine"},
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
}

for _, side in ipairs{"r", "l"} do
	table.insert(
		biped.Parts,
		{Name = "upperarm_" .. side, From = "upperarm_" .. side, To = "forearm_" .. side, Radius = 0.065, Mass = 2, Multiplier = 0.7, Bone = "upperarm_" .. side}
	)
	table.insert(
		biped.Parts,
		{Name = "forearm_" .. side, From = "forearm_" .. side, To = "hand_" .. side, Radius = 0.055, Mass = 1.5, Multiplier = 0.7, Bone = "forearm_" .. side}
	)
	table.insert(
		biped.Parts,
		{Name = "thigh_" .. side, From = "thigh_" .. side, To = "calf_" .. side, Radius = 0.095, Mass = 5, Multiplier = 0.7, Bone = "thigh_" .. side}
	)
	table.insert(
		biped.Parts,
		{Name = "calf_" .. side, From = "calf_" .. side, To = "foot_" .. side, Radius = 0.075, Mass = 3, Multiplier = 0.6, Bone = "calf_" .. side}
	)
end

biped.Joints = {
	{Parent = "pelvis", Child = "torso", Anchor = "spine", Twist = 0.4, Swing = 0.35},
	{Parent = "torso", Child = "head", Anchor = "neck", Twist = 0.8, Swing = 0.5},
}

for _, side in ipairs{"r", "l"} do
	table.insert(biped.Joints, {Parent = "torso", Child = "upperarm_" .. side, Anchor = "upperarm_" .. side, Twist = 1, Swing = 1.5})
	table.insert(
		biped.Joints,
		{Parent = "upperarm_" .. side, Child = "forearm_" .. side, Anchor = "forearm_" .. side, Hinge = {-2.4, 0}}
	)
	table.insert(biped.Joints, {Parent = "pelvis", Child = "thigh_" .. side, Anchor = "thigh_" .. side, Twist = 0.4, Swing = 1})
	table.insert(
		biped.Joints,
		{Parent = "thigh_" .. side, Child = "calf_" .. side, Anchor = "calf_" .. side, Hinge = {0, 2.4}}
	)
end

biped.SourceBones = {
	body = "ValveBiped.Bip01_Pelvis",
	spine = "ValveBiped.Bip01_Spine1",
	chest = "ValveBiped.Bip01_Spine2",
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
	grip_r = {Bone = "hand_r", Offset = Vec3(0, 0.08, 0.16)},
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
