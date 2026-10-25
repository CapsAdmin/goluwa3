local T = import("test/environment.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
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
