local Matrix44 = import("goluwa/structs/matrix44.lua")
local aim_pose = import("lua/aim_pose.lua")
local roll_pose = {}
roll_pose.Hunch = -0.1875
roll_pose.Head = -0.1125
roll_pose.Thigh = 0.525
roll_pose.Calf = -0.75
roll_pose.UpperArm = 0.3375
roll_pose.Forearm = 0.4125
roll_pose.Wobble = 0.35
local UPPER = {
	"spine",
	"chest",
	"back",
	"neck",
	"head",
	"clavicle_r",
	"upperarm_r",
	"forearm_r",
	"hand_r",
	"clavicle_l",
	"upperarm_l",
	"forearm_l",
	"hand_l",
}
local HEAD = {"head"}
local LEG_R = {"thigh_r", "calf_r", "foot_r"}
local LEG_L = {"thigh_l", "calf_l", "foot_l"}
local ARM_R = {"upperarm_r", "forearm_r", "hand_r"}
local ARM_L = {"upperarm_l", "forearm_l", "hand_l"}
local LOWER_LEG_R = {"calf_r", "foot_r"}
local LOWER_LEG_L = {"calf_l", "foot_l"}
local FOREARM_R = {"forearm_r", "hand_r"}
local FOREARM_L = {"forearm_l", "hand_l"}
local TURN = math.pi * 2
local FREQUENCY = {1, 2, 1, 3, 2, 3, 1, 2, 3, 1}
local rotation = Matrix44():Identity()

local function pitch(bones, names, count, pivot, angle)
	local c, s = math.cos(angle), math.sin(angle)
	rotation.m11, rotation.m12, rotation.m21, rotation.m22 = c, s, -s, c
	aim_pose.RotateChain(bones, names, count, bones[pivot], rotation)
end

local function noise(amount, angle, phase, i)
	return amount * (
			1 + roll_pose.Wobble * math.sin(angle * FREQUENCY[i] + i * 1.3 + phase)
		)
end

function roll_pose.Apply(bones, amount, angle, seed)
	local phase = seed * TURN
	pitch(bones, UPPER, #UPPER, "waist", roll_pose.Hunch * noise(amount, angle, phase, 1))
	pitch(bones, HEAD, 1, "neck", roll_pose.Head * noise(amount, angle, phase, 2))
	pitch(bones, LEG_R, 3, "thigh_r", roll_pose.Thigh * noise(amount, angle, phase, 3))
	pitch(bones, LOWER_LEG_R, 2, "calf_r", roll_pose.Calf * noise(amount, angle, phase, 4))
	pitch(bones, LEG_L, 3, "thigh_l", roll_pose.Thigh * noise(amount, angle, phase, 5))
	pitch(bones, LOWER_LEG_L, 2, "calf_l", roll_pose.Calf * noise(amount, angle, phase, 6))
	pitch(
		bones,
		ARM_R,
		3,
		"upperarm_r",
		roll_pose.UpperArm * noise(amount, angle, phase, 7)
	)
	pitch(
		bones,
		FOREARM_R,
		2,
		"forearm_r",
		roll_pose.Forearm * noise(amount, angle, phase, 8)
	)
	pitch(
		bones,
		ARM_L,
		3,
		"upperarm_l",
		roll_pose.UpperArm * noise(amount, angle, phase, 9)
	)
	pitch(
		bones,
		FOREARM_L,
		2,
		"forearm_l",
		roll_pose.Forearm * noise(amount, angle, phase, 10)
	)
end

return roll_pose
