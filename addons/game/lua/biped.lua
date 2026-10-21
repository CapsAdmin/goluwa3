local Vec3 = import("goluwa/structs/vec3.lua")
local biped = {}
biped.SkeletonName = "biped"
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
