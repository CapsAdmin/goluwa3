local T = import("test/environment.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local aim_pose = import("lua/aim_pose.lua")
local leg_pose = import("lua/leg_pose.lua")
local POSITIONS = {
	body = Vec3(0, 0.9, 0),
	waist = Vec3(0, 0.95, 0),
	spine = Vec3(0, 1, 0),
	chest = Vec3(0, 1.1, 0),
	back = Vec3(0, 1.25, 0),
	neck = Vec3(0, 1.4, 0),
	head = Vec3(0, 1.5, 0),
	clavicle_r = Vec3(0.05, 1.38, 0),
	upperarm_r = Vec3(0.17, 1.35, 0),
	forearm_r = Vec3(0.17, 1.12, 0),
	hand_r = Vec3(0.17, 0.9, 0),
	clavicle_l = Vec3(-0.05, 1.38, 0),
	upperarm_l = Vec3(-0.17, 1.35, 0),
	forearm_l = Vec3(-0.17, 1.12, 0),
	hand_l = Vec3(-0.17, 0.9, 0),
	thigh_r = Vec3(0.1, 0.85, 0),
	calf_r = Vec3(0.1, 0.47, -0.03),
	foot_r = Vec3(0.1, 0.08, 0),
	thigh_l = Vec3(-0.1, 0.85, 0),
	calf_l = Vec3(-0.1, 0.47, -0.03),
	foot_l = Vec3(-0.1, 0.08, 0),
}
local NORMALS = {Vec3(0, 1, 0), Vec3(0, 1, 0)}

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

T.Test("a raised foot reaches its target and the leg keeps its bone lengths", function()
	local bones = create_bones()
	leg_pose.Apply(bones, 0.15, 0, 0, NORMALS)
	T(position(bones, "foot_r").y)["~"](0.23, 1e-4)
	T(position(bones, "foot_l"):Distance(POSITIONS.foot_l))["<"](1e-4)
	T(position(bones, "thigh_r"):Distance(position(bones, "calf_r")))["~"](POSITIONS.thigh_r:Distance(POSITIONS.calf_r), 1e-4)
	T(position(bones, "calf_r"):Distance(position(bones, "foot_r")))["~"](POSITIONS.calf_r:Distance(POSITIONS.foot_r), 1e-4)
	T(position(bones, "calf_r").z)["<"](0)
end)

T.Test("a knee that would bend backwards is turned to bend forwards", function()
	local bones = create_bones()
	bones.calf_r:SetTranslation(0.1, 0.47, 0.03)
	leg_pose.Apply(bones, 0.1, 0, 0, NORMALS)
	local foot = position(bones, "foot_r")
	local thigh = position(bones, "thigh_r")
	local knee = position(bones, "calf_r")
	local axis = (foot - thigh):GetNormalized()
	local bend = (knee - thigh) - axis * (knee - thigh):Dot(axis)
	T(bend:GetNormalized():Dot(Vec3(0, 0, -1)))[">"](leg_pose.KneeForward - 0.02)
end)

T.Test("the pelvis shift lowers everything above the feet and the feet stay on their targets", function()
	local bones = create_bones()
	leg_pose.Apply(bones, -0.1, -0.1, -0.1, NORMALS)
	T(position(bones, "head").y)["~"](POSITIONS.head.y - 0.1, 1e-6)
	T(position(bones, "foot_r").y)["~"](POSITIONS.foot_r.y - 0.1, 1e-4)
	T(position(bones, "foot_l").y)["~"](POSITIONS.foot_l.y - 0.1, 1e-4)
end)

T.Test("a foot tilts to the ground normal but not past the maximum", function()
	local bones = create_bones()
	local normals = {Vec3(0.7071, 0.7071, 0), Vec3(0, 1, 0)}
	leg_pose.Apply(bones, 0, 0, 0, normals)
	local up = bones.foot_r:GetRotation():GetUp()
	local angle = math.acos(math.clamp(up:Dot(Vec3(0, 1, 0)), -1, 1))
	T(angle)["~"](leg_pose.MaxTilt, 0.02)
	T(bones.foot_l:GetRotation():GetUp():Dot(Vec3(0, 1, 0)))["~"](1, 1e-4)
end)

local function knee_direction(bones)
	local foot = position(bones, "foot_r")
	local thigh = position(bones, "thigh_r")
	local knee = position(bones, "calf_r")
	local axis = (foot - thigh):GetNormalized()
	return ((knee - thigh) - axis * (knee - thigh):Dot(axis)):GetNormalized(), axis
end

T.Test("a knee pointing outwards while the foot is raised is pulled back within the forward cone", function()
	local bones = create_bones()
	bones.calf_r:SetTranslation(0.25, 0.47, -0.02)
	leg_pose.Apply(bones, 0.2, 0, 0, NORMALS)
	local bend, axis = knee_direction(bones)
	local forward = (Vec3(0, 0, -1) - axis * Vec3(0, 0, -1):Dot(axis)):GetNormalized()
	T(bend:Dot(forward))[">"](leg_pose.KneeForward - 0.02)
	T(bend.x)[">="](0)
end)

T.Test("a nearly straight leg has no stable knee direction and bends forward", function()
	local bones = create_bones()
	bones.calf_r:SetTranslation(0.1 + 0.004, 0.47, 0)
	leg_pose.Apply(bones, 0.02, 0, 0, NORMALS)
	local bend, axis = knee_direction(bones)
	local forward = (Vec3(0, 0, -1) - axis * Vec3(0, 0, -1):Dot(axis)):GetNormalized()
	T(bend:Dot(forward))[">"](0.95)
end)

T.Test("pelvis keys move the body over planted feet and the legs keep their bone lengths", function()
	local animations = import("lua/animations.lua")
	animations.Register(
		"leg_keys_test",
		{
			Kind = "action",
			PelvisKeys = {{0, 0, 0, 0, 0, 0, 0}, {1, 0.1, -0.1, 0.2, 0.5, 0, 0}},
		}
	)
	local inst = animations.NewInstance("leg_keys_test", 1)
	inst.phase = 1

	for _, side in ipairs{1, -1} do
		local bones = create_bones()
		local state = leg_pose.NewState()
		leg_pose.ApplyKeys(bones, {anims = {inst}}, side, state)
		leg_pose.Apply(bones, 0, 0, 0, NORMALS, state)
		T(position(bones, "head").y)["~"](POSITIONS.head.y - 0.1, 1e-5)
		T(position(bones, "foot_r"):Distance(POSITIONS.foot_r))["~"](0, 1e-4)
		T(position(bones, "foot_l"):Distance(POSITIONS.foot_l))["~"](0, 1e-4)

		for _, leg in ipairs{"r", "l"} do
			T(position(bones, "thigh_" .. leg):Distance(position(bones, "calf_" .. leg)))["~"](POSITIONS.thigh_r:Distance(POSITIONS.calf_r), 1e-4)
			T(position(bones, "calf_" .. leg):Distance(position(bones, "foot_" .. leg)))["~"](POSITIONS.calf_r:Distance(POSITIONS.foot_r), 1e-4)
		end
	end
end)

T.Test("a planted foot follows part of the pelvis yaw", function()
	local animations = import("lua/animations.lua")
	local inst = animations.NewInstance("leg_keys_test", 1)
	inst.phase = 1
	local bones = create_bones()
	local state = leg_pose.NewState()
	leg_pose.ApplyKeys(bones, {anims = {inst}}, 1, state)
	local forward = bones.foot_r:GetRotation():VecMul(Vec3(0, 0, -1))
	T(math.atan2(-forward.x, -forward.z))["~"](0.5 * leg_pose.FootYawFollow, 1e-4)
end)

T.Test("a pelvis hook moves the body and the head holds most of the pelvis rotation", function()
	local animations = import("lua/animations.lua")
	animations.Register(
		"pelvis_hook_test",
		{
			Kind = "action",
			Pelvis = function(inst, pose, out)
				out[1], out[2], out[3], out[4], out[5], out[6] = 0.1, 0, 0, 0, 0.5, 0
			end,
		}
	)
	local bones = create_bones()
	local inst = animations.NewInstance("pelvis_hook_test", 1)
	local state = leg_pose.NewState()
	leg_pose.ApplyKeys(bones, {anims = {inst}}, 1, state)
	leg_pose.Apply(bones, 0, 0, 0, NORMALS, state)
	T(bones.chest:GetRotation():GetForward().y > 0.4)["=="](true)
	T(bones.head:GetRotation():GetForward().y)["~"](math.sin(0.5 * (1 - leg_pose.HeadHold)), 0.03)
	T(position(bones, "foot_r"):Distance(POSITIONS.foot_r) < 0.02)["=="](true)
end)

T.Test("a creature limb reaches a lowered target, keeps its bone lengths and the side it bends to", function()
	local bones = {}

	for name, at in pairs{upper = Vec3(0, 1, 0), lower = Vec3(0.4, 1.3, 0), tip = Vec3(0.8, 0.3, 0)} do
		bones[name] = Matrix44():Identity():SetTranslation(at.x, at.y, at.z)
	end

	local limb = leg_pose.NewLimb("upper", "lower", "tip")
	local upper, lower, tip = position(bones, "upper"), position(bones, "lower"), position(bones, "tip")
	local upper_length, lower_length = upper:Distance(lower), lower:Distance(tip)
	leg_pose.SolveLimb(bones, limb, 0.8, 0.1, 0.1, Vec3(0, 1, 0))
	T(position(bones, "tip"):Distance(Vec3(0.8, 0.1, 0.1)))["<"](1e-3)
	T(position(bones, "upper"):Distance(position(bones, "lower")))["~"](upper_length, 1e-4)
	T(position(bones, "lower"):Distance(position(bones, "tip")))["~"](lower_length, 1e-4)
	local axis = (position(bones, "tip") - position(bones, "upper")):GetNormalized()
	local knee = position(bones, "lower") - position(bones, "upper")
	T((knee - axis * knee:Dot(axis)).y > 0.1)["=="](true)
end)

T.Test("a creature limb folds tighter than a knee can", function()
	local bones = {}

	for name, at in pairs{upper = Vec3(0, 1, 0), lower = Vec3(0.5, 1, 0), tip = Vec3(0.1, 1, 0.05)} do
		bones[name] = Matrix44():Identity():SetTranslation(at.x, at.y, at.z)
	end

	local limb = leg_pose.NewLimb("upper", "lower", "tip")
	leg_pose.SolveLimb(bones, limb, 0.1, 1, 0.05, Vec3(0, 1, 0))
	T(position(bones, "tip"):Distance(Vec3(0.1, 1, 0.05)))["<"](1e-3)
end)

T.Test("the sole of a tip bone is the lowest hull vertex of its solid, in the bone frame", function()
	local solid = {
		bone = "Leg.Tip",
		bone_position = Vec3(0, 0.8, 0),
		bone_rotation = Quat(-0.7071067811865476, 0, 0, 0.7071067811865476),
		children = {
			{
				Position = Vec3(0, 0, 0),
				ConvexHull = {vertices = {Vec3(0, 0, 0), Vec3(0, 0, -0.8), Vec3(0.05, 0, -0.4)}},
			},
		},
	}
	local soles = leg_pose.GetSoles({solids = {solid}}, {"leg.tip", "missing"})
	T(soles[1] ~= false)["=="](true)
	T(soles[1]:Distance(Vec3(0, 0, -0.8)))["<"](1e-6)
	T(soles[2])["=="](false)
end)
