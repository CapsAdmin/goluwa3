local Matrix44 = import("goluwa/structs/matrix44.lua")
local Quat = import("goluwa/structs/quat.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local aim_pose = {}
aim_pose.Shares = {spine = 0.15, chest = 0.2, neck = 0.25, head = 0.4}
aim_pose.RecoilAngle = math.rad(6)
aim_pose.FlinchAngle = math.rad(10)
aim_pose.ArmReach = 0.85
aim_pose.HandOffset = Vec3(-0.08, -0.1, 0)
aim_pose.ElbowPole = Vec3(0.6, -1, 0.2)
local ARMS = {
	"clavicle_r",
	"upperarm_r",
	"forearm_r",
	"hand_r",
	"clavicle_l",
	"upperarm_l",
	"forearm_l",
	"hand_l",
}
local JOINTS = {
	{"spine", {"spine", "chest", "neck", "head", unpack(ARMS)}},
	{"chest", {"chest", "neck", "head", unpack(ARMS)}},
	{"neck", {"neck", "head"}},
	{"head", {"head"}},
}
local RIGHT_ARM = {"upperarm_r", "forearm_r", "hand_r"}
local RIGHT_FOREARM = {"forearm_r", "hand_r"}
local identity = Quat(0, 0, 0, 1)
local rotation = Matrix44()
local grip = Matrix44()
local offset = Vec3()
local shoulder, elbow, hand_target, direction = Vec3(), Vec3(), Vec3(), Vec3()
local between = Quat()

local function rotate_about(m, px, py, pz, r)
	local x, y, z = m.m30 - px, m.m31 - py, m.m32 - pz
	m.m30 = px + x * r.m00 + y * r.m10 + z * r.m20
	m.m31 = py + x * r.m01 + y * r.m11 + z * r.m21
	m.m32 = pz + x * r.m02 + y * r.m12 + z * r.m22
	local a, b, c = m.m00, m.m01, m.m02
	m.m00, m.m01, m.m02 = a * r.m00 + b * r.m10 + c * r.m20, a * r.m01 + b * r.m11 + c * r.m21, a * r.m02 + b * r.m12 + c * r.m22
	a, b, c = m.m10, m.m11, m.m12
	m.m10, m.m11, m.m12 = a * r.m00 + b * r.m10 + c * r.m20, a * r.m01 + b * r.m11 + c * r.m21, a * r.m02 + b * r.m12 + c * r.m22
	a, b, c = m.m20, m.m21, m.m22
	m.m20, m.m21, m.m22 = a * r.m00 + b * r.m10 + c * r.m20, a * r.m01 + b * r.m11 + c * r.m21, a * r.m02 + b * r.m12 + c * r.m22
end

local function rotate_chain(bones, names, count, pivot, r)
	local px, py, pz = pivot.m30, pivot.m31, pivot.m32

	for i = 1, count do
		rotate_about(bones[names[i]], px, py, pz, r)
	end
end

local function set_between(out, ax, ay, az, bx, by, bz)
	local al = math.sqrt(ax * ax + ay * ay + az * az)
	local bl = math.sqrt(bx * bx + by * by + bz * bz)
	ax, ay, az, bx, by, bz = ax / al, ay / al, az / al, bx / bl, by / bl, bz / bl
	local cx, cy, cz = ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx
	local length = math.sqrt(cx * cx + cy * cy + cz * cz)

	if length < 1e-6 then return out:Set(0, 0, 0, 1) end

	local half = math.atan2(length, ax * bx + ay * by + az * bz) / 2
	local s = math.sin(half) / length
	return out:Set(cx * s, cy * s, cz * s, math.cos(half))
end

aim_pose.Bones = {"spine", "chest", "neck", "head", unpack(ARMS)}

function aim_pose.GetGripMatrix(hand, pitch)
	grip:Identity()
	grip:SetRotation(pitch)
	grip:SetTranslation(hand.m30, hand.m31, hand.m32)
	return grip
end

function aim_pose.GetAim(pose)
	if pose.recoil <= 0 then return pose.pitch end

	return pose.pitch:Copy():RotatePitch(aim_pose.RecoilAngle * pose.recoil)
end

function aim_pose.Apply(bones, pose, armed)
	local pitch = aim_pose.GetAim(pose)
	local flinch = pose.flinch * aim_pose.FlinchAngle

	for _, joint in ipairs(JOINTS) do
		local name = joint[1]
		local share = aim_pose.Shares[name]
		local angle_pitch = pitch

		if flinch > 0 and (name == "spine" or name == "chest") then
			angle_pitch = pitch:Copy():RotatePitch(flinch / share)
		end

		rotation:SetRotation(identity:GetLerped(share, angle_pitch):Normalize())
		rotate_chain(bones, joint[2], #joint[2], bones[name], rotation)
	end

	if not armed then return end

	local upper, lower, hand = bones.upperarm_r, bones.forearm_r, bones.hand_r
	shoulder:Set(upper.m30, upper.m31, upper.m32)
	local upper_length = math.sqrt((lower.m30 - upper.m30) ^ 2 + (lower.m31 - upper.m31) ^ 2 + (lower.m32 - upper.m32) ^ 2)
	local lower_length = math.sqrt((hand.m30 - lower.m30) ^ 2 + (hand.m31 - lower.m31) ^ 2 + (hand.m32 - lower.m32) ^ 2)
	local reach = (upper_length + lower_length) * aim_pose.ArmReach
	offset:Set(aim_pose.HandOffset.x, aim_pose.HandOffset.y, -reach)
	Quat.SetVecMul(hand_target, pitch, offset)
	hand_target:Set(hand_target.x + shoulder.x, hand_target.y + shoulder.y, hand_target.z + shoulder.z)
	local dx, dy, dz = hand_target.x - shoulder.x, hand_target.y - shoulder.y, hand_target.z - shoulder.z
	local distance = math.max(math.sqrt(dx * dx + dy * dy + dz * dz), 1e-3)
	local limit = (upper_length + lower_length) * 0.999
	local clamped = math.min(distance, limit)
	local along = (upper_length * upper_length - lower_length * lower_length + clamped * clamped) / (2 * clamped)
	local height = math.sqrt(math.max(upper_length * upper_length - along * along, 0))
	dx, dy, dz = dx / distance, dy / distance, dz / distance
	Quat.SetVecMul(direction, pitch, aim_pose.ElbowPole)
	local pole_along = direction.x * dx + direction.y * dy + direction.z * dz
	local bx, by, bz = direction.x - dx * pole_along, direction.y - dy * pole_along, direction.z - dz * pole_along
	local bend = math.sqrt(bx * bx + by * by + bz * bz)
	bx, by, bz = bx / bend, by / bend, bz / bend
	elbow:Set(
		shoulder.x + dx * along + bx * height,
		shoulder.y + dy * along + by * height,
		shoulder.z + dz * along + bz * height
	)
	hand_target:Set(shoulder.x + dx * clamped, shoulder.y + dy * clamped, shoulder.z + dz * clamped)
	set_between(
		between,
		lower.m30 - upper.m30,
		lower.m31 - upper.m31,
		lower.m32 - upper.m32,
		elbow.x - shoulder.x,
		elbow.y - shoulder.y,
		elbow.z - shoulder.z
	)
	rotation:SetRotation(between)
	rotate_chain(bones, RIGHT_ARM, 3, upper, rotation)
	set_between(
		between,
		hand.m30 - lower.m30,
		hand.m31 - lower.m31,
		hand.m32 - lower.m32,
		hand_target.x - elbow.x,
		hand_target.y - elbow.y,
		hand_target.z - elbow.z
	)
	rotation:SetRotation(between)
	rotate_chain(bones, RIGHT_FOREARM, 2, lower, rotation)
	hand:SetTranslation(hand_target.x, hand_target.y, hand_target.z)
end

return aim_pose
