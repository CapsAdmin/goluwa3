local Matrix44 = import("goluwa/structs/matrix44.lua")
local Quat = import("goluwa/structs/quat.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local pose_variation = import("lua/pose_variation.lua")
local animations = import("lua/animations.lua")
local aim_pose = {}
local ZERO = Vec3()
aim_pose.Shares = {waist = 0.08, spine = 0.12, chest = 0.15, back = 0.15, neck = 0.2, head = 0.3}
aim_pose.ClavicleShare = 0.25
aim_pose.ElbowFlexion = 2.4
aim_pose.ArmReach = 0.85
aim_pose.HandOffset = Vec3(-0.08, -0.1, 0)
aim_pose.NeutralHand = Vec3(0.02, -0.36, -0.12)
aim_pose.PalmOffset = Vec3(0.02, 0, -0.04)
aim_pose.ElbowPole = Vec3(0.6, -1, 0.2)
aim_pose.BlockOffset = Vec3(0.12, -0.02, 0)
aim_pose.BlockReach = -0.18
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
local SPINE = {"waist", "spine", "chest", "back", "neck", "head"}
local JOINTS = {}

for i, name in ipairs(SPINE) do
	local chain = {unpack(SPINE, i)}

	for _, arm in ipairs(ARMS) do
		chain[#chain + 1] = arm
	end

	JOINTS[i] = {name, chain}
end

local RIGHT = {
	upper = "upperarm_r",
	lower = "forearm_r",
	hand = "hand_r",
	clavicle = "clavicle_r",
	shoulder_chain = {"clavicle_r", "upperarm_r", "forearm_r", "hand_r"},
	chain = {"upperarm_r", "forearm_r", "hand_r"},
	forearm_chain = {"forearm_r", "hand_r"},
}
local LEFT = {
	upper = "upperarm_l",
	lower = "forearm_l",
	hand = "hand_l",
	clavicle = "clavicle_l",
	shoulder_chain = {"clavicle_l", "upperarm_l", "forearm_l", "hand_l"},
	chain = {"upperarm_l", "forearm_l", "hand_l"},
	forearm_chain = {"forearm_l", "hand_l"},
}
local identity = Quat(0, 0, 0, 1)
local lean = Quat(0, 0, 0, 1)
local rotation = Matrix44()
local grip = Matrix44()
local grip_target = Vec3()
local hand_rotation = Quat()
local shift = Vec3()
local wrist_r, wrist_l, shoulder_r, shoulder_l = Vec3(), Vec3(), Vec3(), Vec3()
local palm = Vec3()
local right_roll = Quat(0, 0, 1, 0)
local left_roll = Quat()
local offset = Vec3()
local shoulder, elbow, hand_target, direction = Vec3(), Vec3(), Vec3(), Vec3()
local between = Quat()

local function rotate_about(m, px, py, pz, r)
	local x, y, z = m.m30 - px, m.m31 - py, m.m32 - pz
	m.m30 = px + x * r.m00 + y * r.m10 + z * r.m20
	m.m31 = py + x * r.m01 + y * r.m11 + z * r.m21
	m.m32 = pz + x * r.m02 + y * r.m12 + z * r.m22
	local a, b, c = m.m00, m.m01, m.m02
	m.m00, m.m01, m.m02 = a * r.m00 + b * r.m10 + c * r.m20,
	a * r.m01 + b * r.m11 + c * r.m21,
	a * r.m02 + b * r.m12 + c * r.m22
	a, b, c = m.m10, m.m11, m.m12
	m.m10, m.m11, m.m12 = a * r.m00 + b * r.m10 + c * r.m20,
	a * r.m01 + b * r.m11 + c * r.m21,
	a * r.m02 + b * r.m12 + c * r.m22
	a, b, c = m.m20, m.m21, m.m22
	m.m20, m.m21, m.m22 = a * r.m00 + b * r.m10 + c * r.m20,
	a * r.m01 + b * r.m11 + c * r.m21,
	a * r.m02 + b * r.m12 + c * r.m22
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

local function get_fold(upper_length, lower_length)
	return math.sqrt(
		upper_length * upper_length + lower_length * lower_length + 2 * upper_length * lower_length * math.cos(aim_pose.ElbowFlexion)
	)
end

local function get_length(a, b)
	return math.sqrt((a.m30 - b.m30) ^ 2 + (a.m31 - b.m31) ^ 2 + (a.m32 - b.m32) ^ 2)
end

local function get_correction(wrist, shoulder_position, upper_length, lower_length)
	local dx, dy, dz = wrist.x - shoulder_position.x,
	wrist.y - shoulder_position.y,
	wrist.z - shoulder_position.z
	local distance = math.max(math.sqrt(dx * dx + dy * dy + dz * dz), 1e-3)
	local fold = get_fold(upper_length, lower_length)
	local limit = (upper_length + lower_length) * 0.999
	local scale = 0

	if distance < fold then
		scale = (fold - distance) / distance
	elseif distance > limit then
		scale = (limit - distance) / distance
	end

	return dx * scale, dy * scale, dz * scale
end

local function compute_shift(bones, pitch, weapon)
	local two_handed = weapon:IsTwoHanded()
	local upper_r, upper_l = bones.upperarm_r, bones.upperarm_l
	local right_upper = get_length(upper_r, bones.forearm_r)
	local right_lower = get_length(bones.forearm_r, bones.hand_r)
	local hold_offset = weapon:GetHoldOffset()
	shoulder_r:Set(upper_r.m30, upper_r.m31, upper_r.m32)

	if weapon:IsHoldFromHead() then
		local head = bones.head
		Quat.SetVecMul(wrist_r, pitch, hold_offset)
		wrist_r:Set(head.m30 + wrist_r.x, head.m31 + wrist_r.y, head.m32 + wrist_r.z)
	else
		offset:Set(aim_pose.HandOffset.x, aim_pose.HandOffset.y, -(right_upper + right_lower) * aim_pose.ArmReach)
		Quat.SetVecMul(wrist_r, pitch, offset)
		wrist_r:Set(
			wrist_r.x + shoulder_r.x + hold_offset.x,
			wrist_r.y + shoulder_r.y + hold_offset.y,
			wrist_r.z + shoulder_r.z + hold_offset.z
		)
	end

	if two_handed then
		Quat.SetVecMul(wrist_l, pitch, weapon:GetSupportGrip())
		wrist_l:Set(wrist_l.x + wrist_r.x, wrist_l.y + wrist_r.y, wrist_l.z + wrist_r.z)
	end

	hand_rotation:SetMul(pitch, right_roll)
	Quat.SetVecMul(palm, hand_rotation, aim_pose.PalmOffset)
	wrist_r:Set(wrist_r.x - palm.x, wrist_r.y - palm.y, wrist_r.z - palm.z)
	local left_upper, left_lower

	if two_handed then
		left_upper = get_length(upper_l, bones.forearm_l)
		left_lower = get_length(bones.forearm_l, bones.hand_l)
		shoulder_l:Set(upper_l.m30, upper_l.m31, upper_l.m32)
		local half = weapon:GetSupportRoll() / 2
		left_roll:Set(0, 0, math.sin(half), math.cos(half))
		hand_rotation:SetMul(pitch, left_roll)
		Quat.SetVecMul(palm, hand_rotation, aim_pose.PalmOffset)
		wrist_l:Set(wrist_l.x - palm.x, wrist_l.y - palm.y, wrist_l.z - palm.z)
	end

	local weight = two_handed and 0.5 or 1
	local sx, sy, sz = 0, 0, 0

	for _ = 1, 4 do
		wrist_r:Set(wrist_r.x + sx, wrist_r.y + sy, wrist_r.z + sz)
		local rx, ry, rz = get_correction(wrist_r, shoulder_r, right_upper, right_lower)
		local lx, ly, lz = 0, 0, 0

		if two_handed then
			wrist_l:Set(wrist_l.x + sx, wrist_l.y + sy, wrist_l.z + sz)
			lx, ly, lz = get_correction(wrist_l, shoulder_l, left_upper, left_lower)
		end

		sx, sy, sz = (rx + lx) * weight, (ry + ly) * weight, (rz + lz) * weight
		shift:Set(shift.x + sx, shift.y + sy, shift.z + sz)
	end
end

local function solve_arm(
	bones,
	arm,
	pitch,
	hand_offset,
	extra_reach,
	side,
	hold_offset,
	support,
	roll,
	head_hold
)
	local upper, lower, hand = bones[arm.upper], bones[arm.lower], bones[arm.hand]
	shoulder:Set(upper.m30, upper.m31, upper.m32)
	local upper_length = math.sqrt((lower.m30 - upper.m30) ^ 2 + (lower.m31 - upper.m31) ^ 2 + (lower.m32 - upper.m32) ^ 2)
	local lower_length = math.sqrt((hand.m30 - lower.m30) ^ 2 + (hand.m31 - lower.m31) ^ 2 + (hand.m32 - lower.m32) ^ 2)

	if support then
		Quat.SetVecMul(hand_target, pitch, support)
		hand_target:Set(
			hand_target.x + grip_target.x,
			hand_target.y + grip_target.y,
			hand_target.z + grip_target.z
		)
	elseif head_hold then
		local head = bones.head
		Quat.SetVecMul(hand_target, pitch, hold_offset)
		hand_target:Set(
			head.m30 + hand_target.x + shift.x,
			head.m31 + hand_target.y + shift.y,
			head.m32 + hand_target.z + shift.z
		)
		grip_target:Set(hand_target.x, hand_target.y, hand_target.z)
	else
		local reach = (upper_length + lower_length) * aim_pose.ArmReach + extra_reach
		offset:Set(hand_offset.x * side, hand_offset.y, -reach)
		Quat.SetVecMul(hand_target, pitch, offset)
		hand_target:Set(
			hand_target.x + shoulder.x + hold_offset.x + shift.x,
			hand_target.y + shoulder.y + hold_offset.y + shift.y,
			hand_target.z + shoulder.z + hold_offset.z + shift.z
		)
		grip_target:Set(hand_target.x, hand_target.y, hand_target.z)
	end

	if roll then
		hand_rotation:SetMul(pitch, roll)
		Quat.SetVecMul(palm, hand_rotation, aim_pose.PalmOffset)
		hand_target:Set(hand_target.x - palm.x, hand_target.y - palm.y, hand_target.z - palm.z)
	end

	local clavicle = bones[arm.clavicle]
	set_between(
		between,
		upper.m30 - clavicle.m30,
		upper.m31 - clavicle.m31,
		upper.m32 - clavicle.m32,
		hand_target.x - clavicle.m30,
		hand_target.y - clavicle.m31,
		hand_target.z - clavicle.m32
	)
	rotation:SetRotation(identity:GetLerped(aim_pose.ClavicleShare, between):Normalize())
	rotate_chain(bones, arm.shoulder_chain, 4, clavicle, rotation)
	shoulder:Set(upper.m30, upper.m31, upper.m32)
	local dx, dy, dz = hand_target.x - shoulder.x, hand_target.y - shoulder.y, hand_target.z - shoulder.z
	local distance = math.max(math.sqrt(dx * dx + dy * dy + dz * dz), 1e-3)
	local limit = (upper_length + lower_length) * 0.999
	local fold = get_fold(upper_length, lower_length)
	local clamped = math.clamp(distance, fold, limit)
	local along = (
			upper_length * upper_length - lower_length * lower_length + clamped * clamped
		) / (
			2 * clamped
		)
	local height = math.sqrt(math.max(upper_length * upper_length - along * along, 0))
	dx, dy, dz = dx / distance, dy / distance, dz / distance
	offset:Set(aim_pose.ElbowPole.x * side, aim_pose.ElbowPole.y, aim_pose.ElbowPole.z)
	Quat.SetVecMul(direction, pitch, offset)
	local pole_along = direction.x * dx + direction.y * dy + direction.z * dz
	local bx, by, bz = direction.x - dx * pole_along,
	direction.y - dy * pole_along,
	direction.z - dz * pole_along
	local bend = math.sqrt(bx * bx + by * by + bz * bz)
	bx, by, bz = bx / bend, by / bend, bz / bend
	elbow:Set(
		shoulder.x + dx * along + bx * height,
		shoulder.y + dy * along + by * height,
		shoulder.z + dz * along + bz * height
	)
	hand_target:Set(shoulder.x + dx * clamped, shoulder.y + dy * clamped, shoulder.z + dz * clamped)

	if roll and not support then
		grip_target:Set(hand_target.x + palm.x, hand_target.y + palm.y, hand_target.z + palm.z)
	end

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
	rotate_chain(bones, arm.chain, 3, upper, rotation)
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
	rotate_chain(bones, arm.forearm_chain, 2, lower, rotation)

	if roll then hand:SetRotation(hand_rotation) end

	hand:SetTranslation(hand_target.x, hand_target.y, hand_target.z)
end

local LOWER = {"body", "thigh_r", "calf_r", "foot_r", "thigh_l", "calf_l", "foot_l"}
local FEET = {"foot_r", "foot_l"}
local LEAN_BONES = {unpack(JOINTS[1][2])}
aim_pose.Bones = {unpack(SPINE)}

for _, name in ipairs(ARMS) do
	aim_pose.Bones[#aim_pose.Bones + 1] = name
end

for _, name in ipairs(LOWER) do
	LEAN_BONES[#LEAN_BONES + 1] = name
	aim_pose.Bones[#aim_pose.Bones + 1] = name
end

local origin = Matrix44():Identity()

function aim_pose.GetGripMatrix(hand, pitch)
	local p = aim_pose.PalmOffset
	grip:Identity()
	grip:SetRotation(pitch)
	grip:SetTranslation(
		hand.m30 + p.x * hand.m00 + p.y * hand.m10 + p.z * hand.m20,
		hand.m31 + p.x * hand.m01 + p.y * hand.m11 + p.z * hand.m21,
		hand.m32 + p.x * hand.m02 + p.y * hand.m12 + p.z * hand.m22
	)
	return grip
end

function aim_pose.GetFollowGripMatrix(hand, is_right)
	hand_rotation:SetMul(hand:GetRotation(), is_right and right_roll or identity)
	grip:Identity()
	grip:SetRotation(hand_rotation)
	local p = aim_pose.PalmOffset
	grip:SetTranslation(
		hand.m30 + p.x * hand.m00 + p.y * hand.m10 + p.z * hand.m20,
		hand.m31 + p.x * hand.m01 + p.y * hand.m11 + p.z * hand.m21,
		hand.m32 + p.x * hand.m02 + p.y * hand.m12 + p.z * hand.m22
	)
	return grip
end

aim_pose.SetBetween = set_between
aim_pose.RotateChain = rotate_chain

local function sample_action(keys, f)
	for i = 2, #keys do
		local key = keys[i]

		if f <= key[1] then
			local previous = keys[i - 1]
			local t = (f - previous[1]) / (key[1] - previous[1])
			t = t * t * (3 - 2 * t)
			return previous[2] + (key[2] - previous[2]) * t,
			previous[3] + (key[3] - previous[3]) * t
		end
	end

	return 0, 0
end

function aim_pose.GetAim(pose)
	local aim = pose.pitch
	local anims = pose.anims

	for i = 1, #anims do
		local inst = anims[i]
		local def = inst.def

		if def.AimKeys then
			local yaw, pitch = sample_action(def.AimKeys, inst.phase)
			aim = Quat():Identity():RotateYaw(yaw) * aim:Copy():RotatePitch(pitch)
		elseif def.Aim then
			aim = def.Aim(inst, aim)
		end
	end

	return aim
end

function aim_pose.Apply(bones, pose, weapon)
	local pitch = aim_pose.GetAim(pose)
	local flinch = 0

	for i = 1, #pose.anims do
		local torso = pose.anims[i].def.Torso

		if torso then flinch = flinch + torso(pose.anims[i]) end
	end

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

	if not weapon then
		local shares = aim_pose.Shares
		local torso_share = shares.waist + shares.spine + shares.chest + shares.back
		rotation:SetRotation(identity:GetLerped(torso_share, pitch):Normalize():Conjugate())
		rotate_chain(bones, RIGHT.shoulder_chain, 4, bones.clavicle_r, rotation)
		rotate_chain(bones, LEFT.shoulder_chain, 4, bones.clavicle_l, rotation)
	end

	pose_variation.GetLean(lean, pose.lean_side, pose.lean_forward)
	rotation:SetRotation(lean)
	rotate_chain(bones, LEAN_BONES, #LEAN_BONES, origin, rotation)
	rotation:SetRotation(lean:Conjugate())

	for _, name in ipairs(FEET) do
		local foot = bones[name]
		rotate_about(foot, foot.m30, foot.m31, foot.m32, rotation)
	end

	if weapon then
		compute_shift(bones, pitch, weapon)
		solve_arm(
			bones,
			RIGHT,
			pitch,
			aim_pose.HandOffset,
			0,
			1,
			weapon:GetHoldOffset(),
			nil,
			right_roll,
			weapon:IsHoldFromHead()
		)
		shift:Set(0, 0, 0)
	end

	if animations.GetWeight(pose, "block") > 0.5 then
		solve_arm(bones, LEFT, pose.pitch, aim_pose.BlockOffset, aim_pose.BlockReach, -1, ZERO)
	elseif weapon and weapon:IsTwoHanded() then
		local half = weapon:GetSupportRoll() / 2
		left_roll:Set(0, 0, math.sin(half), math.cos(half))
		solve_arm(bones, LEFT, pitch, nil, nil, -1, nil, weapon:GetSupportGrip(), left_roll)
	elseif weapon then
		local upper = bones.upperarm_l
		local neutral = aim_pose.NeutralHand
		grip_target:Set(upper.m30 - neutral.x, upper.m31 + neutral.y, upper.m32 + neutral.z)
		solve_arm(bones, LEFT, identity, nil, nil, -1, nil, ZERO)
	end
end

return aim_pose
