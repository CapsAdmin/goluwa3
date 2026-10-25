local T = import("test/environment.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local Quat = import("goluwa/structs/quat.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local biped = import("lua/biped.lua")
local aim_pose = import("lua/aim_pose.lua")
local POSITIONS = {
	body = Vec3(0, 0.9, 0),
	spine = Vec3(0, 1, 0),
	chest = Vec3(0, 1.2, 0),
	neck = Vec3(0, 1.4, 0),
	head = Vec3(0, 1.5, 0),
	clavicle_r = Vec3(0.1, 1.38, 0),
	upperarm_r = Vec3(0.2, 1.35, 0),
	forearm_r = Vec3(0.2, 1.1, 0),
	hand_r = Vec3(0.2, 0.85, 0),
	clavicle_l = Vec3(-0.1, 1.38, 0),
	upperarm_l = Vec3(-0.2, 1.35, 0),
	forearm_l = Vec3(-0.2, 1.1, 0),
	hand_l = Vec3(-0.2, 0.85, 0),
	thigh_r = Vec3(0.1, 0.85, 0),
	calf_r = Vec3(0.1, 0.45, 0),
	foot_r = Vec3(0.1, 0.08, 0),
	thigh_l = Vec3(-0.1, 0.85, 0),
	calf_l = Vec3(-0.1, 0.45, 0),
	foot_l = Vec3(-0.1, 0.08, 0),
}

local function create_bones()
	local bones = {}

	for name, position in pairs(POSITIONS) do
		bones[name] = Matrix44():Identity():SetTranslation(position.x, position.y, position.z)
	end

	return bones
end

local function position(bones, name)
	return Vec3(bones[name].m30, bones[name].m31, bones[name].m32)
end

local function pose(pitch, recoil, flinch)
	return {
		pitch = pitch,
		recoil = recoil or 0,
		flinch = flinch or 0,
		block_alpha = 0,
		lean_side = 0,
		lean_forward = 0,
	}
end

T.Test("aiming up rotates the bones above the spine about their joints by the shares of the pitch", function()
	local pitch = Quat(0, 0, 0, 1):RotatePitch(math.rad(40))
	local bones = create_bones()
	aim_pose.Apply(bones, pose(pitch), false)
	T(position(bones, "body"):Distance(POSITIONS.body))["<"](1e-6)
	T(position(bones, "spine"):Distance(POSITIONS.spine))["<"](1e-6)
	T(position(bones, "head"):Distance(POSITIONS.head) > 0.01)["=="](true)
	local total = 0

	for _, share in pairs(aim_pose.Shares) do
		total = total + share
	end

	T(total)["~"](1, 1e-6)
	local forward = bones.head:GetRotation():GetForward()
	T(forward.y)["~"](math.sin(math.rad(40)), 0.02)
end)

T.Test("an armed arm reaches out along the aim and the hand takes the aim rotation", function()
	local pitch = Quat(0, 0, 0, 1):RotatePitch(math.rad(20))
	local bones = create_bones()
	local upper = (POSITIONS.upperarm_r - POSITIONS.forearm_r):GetLength()
	local lower = (POSITIONS.forearm_r - POSITIONS.hand_r):GetLength()
	aim_pose.Apply(bones, pose(pitch), true)
	local shoulder = position(bones, "upperarm_r")
	local elbow = position(bones, "forearm_r")
	local hand = position(bones, "hand_r")
	T(shoulder:Distance(elbow))["~"](upper, 1e-4)
	T(elbow:Distance(hand))["~"](lower, 1e-4)
	local out = (hand - shoulder)
	T(out:GetNormalized():Dot(pitch:GetForward()) > 0.9)["=="](true)
	T(
		aim_pose.GetGripMatrix(bones.hand_r, pitch):GetRotation():GetForward():Dot(pitch:GetForward())
	)["~"](1, 1e-3)
	T(bones.upperarm_r:GetRotation():GetForward():Dot(Vec3(0, 0, -1)) < 0.999)["=="](true)
end)

T.Test("recoil kicks the aim up and flinch leans the torso", function()
	local still = aim_pose.GetAim(pose(Quat(0, 0, 0, 1)))
	local kicked = aim_pose.GetAim(pose(Quat(0, 0, 0, 1), 1))
	T(kicked:GetForward().y > still:GetForward().y)["=="](true)
	local rest, leaning = create_bones(), create_bones()
	aim_pose.Apply(rest, pose(Quat(0, 0, 0, 1)), false)
	aim_pose.Apply(leaning, pose(Quat(0, 0, 0, 1), 0, 1), false)
	T(position(leaning, "head"):Distance(position(rest, "head")) > 0.01)["=="](true)
	T(position(leaning, "spine"):Distance(position(rest, "spine")))["<"](1e-6)
end)

T.Test("a two handed weapon puts the support arm out along the aim without stretching it", function()
	local pitch = Quat(0, 0, 0, 1):RotatePitch(math.rad(15))
	local bones = create_bones()
	local upper = (POSITIONS.upperarm_l - POSITIONS.forearm_l):GetLength()
	local lower = (POSITIONS.forearm_l - POSITIONS.hand_l):GetLength()
	aim_pose.Apply(bones, pose(pitch), true, true)
	local shoulder = position(bones, "upperarm_l")
	local elbow = position(bones, "forearm_l")
	local hand = position(bones, "hand_l")
	T(shoulder:Distance(elbow))["~"](upper, 1e-4)
	T(elbow:Distance(hand))["~"](lower, 1e-4)
	T((hand - shoulder):GetNormalized():Dot(pitch:GetForward()) > 0.9)["=="](true)
	local one_handed = create_bones()
	aim_pose.Apply(one_handed, pose(pitch), true, false)
	T(position(one_handed, "hand_l"):Distance(hand) > 0.1)["=="](true)
end)

T.Test("leaning tilts the whole body about the ground and keeps the feet flat", function()
	local level, leaning = create_bones(), create_bones()
	local pitch = Quat(0, 0, 0, 1)
	aim_pose.Apply(level, pose(pitch), false)
	local tilted = pose(pitch)
	tilted.lean_side = 0.2
	aim_pose.Apply(leaning, tilted, false)
	T(position(leaning, "body").x - position(level, "body").x > 0.05)["=="](true)
	T(position(leaning, "head").x - position(level, "head").x > 0.1)["=="](true)
	T(position(leaning, "upperarm_l").x - position(level, "upperarm_l").x > 0.05)["=="](true)
	T(position(leaning, "calf_r").x - position(level, "calf_r").x > 0.02)["=="](true)
	T(position(leaning, "foot_r"):Distance(position(level, "foot_r")) < 0.03)["=="](true)
	local up = leaning.foot_r:GetRotation():GetUp()
	T(up.x)["~"](0, 1e-4)
	T(up.y)["~"](1, 1e-4)
	T(leaning.thigh_r:GetRotation():GetUp().x > 0.1)["=="](true)
	local forward = create_bones()
	tilted.lean_side = 0
	tilted.lean_forward = 0.2
	aim_pose.Apply(forward, tilted, false)
	T(position(forward, "head").z - position(level, "head").z < -0.1)["=="](true)
	T(position(forward, "body").z - position(level, "body").z < -0.05)["=="](true)
	T(forward.foot_l:GetRotation():GetUp().z)["~"](0, 1e-4)
end)
