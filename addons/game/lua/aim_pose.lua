local Matrix44 = import("goluwa/structs/matrix44.lua")
local Quat = import("goluwa/structs/quat.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local pose_variation = import("lua/pose_variation.lua")
local animations = import("lua/animations.lua")
local system = import("goluwa/system.lua")
local aim_pose = {}
local ZERO = Vec3()
local lowered = Quat()
aim_pose.Shares = {waist = 0.08, spine = 0.12, chest = 0.15, back = 0.15, neck = 0.2, head = 0.3}
aim_pose.ClavicleShare = 0.25
aim_pose.HeadLag = 14
aim_pose.HeadTrail = 0.6
aim_pose.ElbowFlexion = 2.4
aim_pose.LoweredPitch = -0.8
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
local HEAD_ONLY = {"head"}
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
local wrist_main, wrist_support, shoulder_main, shoulder_support = Vec3(), Vec3(), Vec3(), Vec3()
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

local function compute_shift(bones, pitch, weapon, arm, side, hold_offset, roll)
	local two_handed = weapon:IsTwoHanded()
	local main_arm, support_arm = bones[arm.upper], bones.upperarm_l
	local main_upper = get_length(main_arm, bones[arm.lower])
	local main_lower = get_length(bones[arm.lower], bones[arm.hand])
	shoulder_main:Set(main_arm.m30, main_arm.m31, main_arm.m32)

	if weapon:IsHoldFromHead() then
		local head = bones.head
		Quat.SetVecMul(wrist_main, pitch, hold_offset)
		wrist_main:Set(head.m30 + wrist_main.x, head.m31 + wrist_main.y, head.m32 + wrist_main.z)
	else
		offset:Set(aim_pose.HandOffset.x * side, aim_pose.HandOffset.y, -(main_upper + main_lower) * aim_pose.ArmReach)
		Quat.SetVecMul(wrist_main, pitch, offset)
		wrist_main:Set(
			wrist_main.x + shoulder_main.x + hold_offset.x,
			wrist_main.y + shoulder_main.y + hold_offset.y,
			wrist_main.z + shoulder_main.z + hold_offset.z
		)
	end

	if two_handed then
		Quat.SetVecMul(wrist_support, pitch, weapon:GetSupportGrip())
		wrist_support:Set(wrist_support.x + wrist_main.x, wrist_support.y + wrist_main.y, wrist_support.z + wrist_main.z)
	end

	hand_rotation:SetMul(pitch, roll)
	Quat.SetVecMul(palm, hand_rotation, aim_pose.PalmOffset)
	wrist_main:Set(wrist_main.x - palm.x, wrist_main.y - palm.y, wrist_main.z - palm.z)
	local support_upper, support_lower

	if two_handed then
		support_upper = get_length(support_arm, bones.forearm_l)
		support_lower = get_length(bones.forearm_l, bones.hand_l)
		shoulder_support:Set(support_arm.m30, support_arm.m31, support_arm.m32)
		local half = weapon:GetSupportRoll() / 2
		left_roll:Set(0, 0, math.sin(half), math.cos(half))
		hand_rotation:SetMul(pitch, left_roll)
		Quat.SetVecMul(palm, hand_rotation, aim_pose.PalmOffset)
		wrist_support:Set(wrist_support.x - palm.x, wrist_support.y - palm.y, wrist_support.z - palm.z)
	end

	local weight = two_handed and 0.5 or 1
	local sx, sy, sz = 0, 0, 0

	for _ = 1, 4 do
		wrist_main:Set(wrist_main.x + sx, wrist_main.y + sy, wrist_main.z + sz)
		local mx, my, mz = get_correction(wrist_main, shoulder_main, main_upper, main_lower)
		local lx, ly, lz = 0, 0, 0

		if two_handed then
			wrist_support:Set(wrist_support.x + sx, wrist_support.y + sy, wrist_support.z + sz)
			lx, ly, lz = get_correction(wrist_support, shoulder_support, support_upper, support_lower)
		end

		sx, sy, sz = (mx + lx) * weight, (my + ly) * weight, (mz + lz) * weight
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
local MATRIX_FIELDS = {}

for row = 0, 3 do
	for column = 0, 3 do
		MATRIX_FIELDS[#MATRIX_FIELDS + 1] = "m" .. row .. column
	end
end

local blend_a, blend_b = Quat(), Quat()

function aim_pose.CopyMatrix(dst, src)
	for i = 1, 16 do
		local field = MATRIX_FIELDS[i]
		dst[field] = src[field]
	end
end

function aim_pose.BlendMatrix(out, a, b, t)
	a:GetRotation(blend_a)
	b:GetRotation(blend_b)

	if blend_a:Dot(blend_b) < 0 then
		blend_b:Set(-blend_b.x, -blend_b.y, -blend_b.z, -blend_b.w)
	end

	out:SetRotation(blend_a:Lerp(t, blend_b):Normalize())
	out:SetTranslation(
		a.m30 + (b.m30 - a.m30) * t,
		a.m31 + (b.m31 - a.m31) * t,
		a.m32 + (b.m32 - a.m32) * t
	)
end

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
local aim_sample = {0, 0}

function aim_pose.GetAim(pose, base)
	local aim = base
	local anims = pose.anims

	for i = 1, #anims do
		local inst = anims[i]
		local def = inst.def

		if def.AimKeys then
			animations.SampleKeys(def.AimKeys, inst.phase, aim_sample, 2)
			local keyed = Quat():Identity():RotateYaw(aim_sample[1]) * aim:Copy():RotatePitch(aim_sample[2])
			aim = inst.weight < 0.999 and aim:GetLerped(inst.weight, keyed):Normalize() or keyed
		elseif def.Aim then
			aim = def.Aim(inst, aim)
		end
	end

	return aim
end

local hand_sample = {0, 0, 0, 0, 0, 0}
local wrist_x, wrist_y, wrist_z, wrist = Quat(), Quat(), Quat(), Quat()
local wrist_mirrored = Quat()
local shift_right, shift_left, shift_aim = Vec3(), Vec3(), Vec3()

function aim_pose.GetHand(pose, out)
	local anims = pose.anims

	for i = 1, 6 do
		out[i] = 0
	end

	for i = 1, #anims do
		local inst = anims[i]
		local keys = inst.def.HandKeys

		if keys then
			animations.SampleKeys(keys, inst.phase, hand_sample, 6)

			for j = 1, 6 do
				out[j] = out[j] + hand_sample[j] * inst.weight
			end
		end
	end

	return out
end

function aim_pose.SetWrist(out, pitch, yaw, roll)
	wrist_x:Set(math.sin(pitch / 2), 0, 0, math.cos(pitch / 2))
	wrist_y:Set(0, math.sin(yaw / 2), 0, math.cos(yaw / 2))
	wrist_z:Set(0, 0, math.sin(roll / 2), math.cos(roll / 2))
	wrist:SetMul(wrist_y, wrist_x)
	return out:SetMul(wrist, wrist_z)
end

local grip_aim = Quat()
local grip_hand = {0, 0, 0, 0, 0, 0}

function aim_pose.GetGripAim(pose, aim, side)
	aim_pose.GetHand(pose, grip_hand)
	aim_pose.SetWrist(wrist_mirrored, grip_hand[4], grip_hand[5] * side, grip_hand[6] * side)
	return grip_aim:SetMul(aim, wrist_mirrored)
end

function aim_pose.GetHoldAim(pose, aim)
	local ready = animations.GetWeight(pose, "ready")

	if ready >= 0.999 then return aim end

	lowered:Identity():RotatePitch(aim_pose.LoweredPitch)
	return lowered:GetLerped(ready, aim):Normalize()
end

local left_start, left_hold = {}, {}

for i = 1, 4 do
	left_start[i] = Matrix44():Identity()
	left_hold[i] = Matrix44():Identity()
end

local mirrored = Vec3()
local hold_roll_right, hold_roll_left = Quat(), Quat()

local function solve_hold(bones, pitch, weapon, arm, side)
	local hold_offset = weapon:GetHoldOffset()
	local roll = side == 1 and hold_roll_right or hold_roll_left
	local hand_shift = side == 1 and shift_right or shift_left
	mirrored:Set(
		hold_offset.x * side + hand_shift.x,
		hold_offset.y + hand_shift.y,
		hold_offset.z + hand_shift.z
	)
	compute_shift(bones, pitch, weapon, arm, side, mirrored, roll)
	solve_arm(
		bones,
		arm,
		pitch,
		aim_pose.HandOffset,
		0,
		side,
		mirrored,
		nil,
		roll,
		weapon:IsHoldFromHead()
	)
	shift:Set(0, 0, 0)
end

local function solve_neutral(bones, arm, side)
	local upper = bones[arm.upper]
	local neutral = aim_pose.NeutralHand
	grip_target:Set(upper.m30 + neutral.x * side, upper.m31 + neutral.y, upper.m32 + neutral.z)
	solve_arm(bones, arm, identity, nil, nil, side, nil, ZERO)
end

do
	local grip_roll = Quat()

	-- position and rotation are the grip in model space, the hand frame follows the weapon grip convention
	function aim_pose.SolveGrip(bones, side, position, rotation)
		grip_target:Set(position.x, position.y, position.z)

		if side == 1 then
			grip_roll:SetMul(rotation, right_roll)
		else
			grip_roll:Set(rotation.x, rotation.y, rotation.z, rotation.w)
		end

		solve_arm(
			bones,
			side == 1 and RIGHT or LEFT,
			identity,
			nil,
			nil,
			side,
			nil,
			ZERO,
			grip_roll
		)
	end
end

local function solve_left_hold(bones, pitch, right, left)
	if right and right:IsTwoHanded() then
		local half = right:GetSupportRoll() / 2
		left_roll:Set(0, 0, math.sin(half), math.cos(half))
		solve_arm(bones, LEFT, pitch, nil, nil, -1, nil, right:GetSupportGrip(), left_roll)
	elseif left then
		solve_hold(bones, pitch, left, LEFT, -1)
	elseif right then
		solve_neutral(bones, LEFT, -1)
	end
end

local head_sample = {1, 0, 0, 0}
local head_keys = {1, 0, 0, 0}

function aim_pose.GetHead(pose)
	local anims = pose.anims
	local follow, nod, turn, tilt = 1, 0, 0, 0

	for i = 1, #anims do
		local inst = anims[i]
		local keys = inst.def.HeadKeys

		if keys then
			animations.SampleKeys(keys, inst.phase, head_sample, 4)
			follow = follow + (head_sample[1] - 1) * inst.weight
			nod = nod + head_sample[2] * inst.weight
			turn = turn + head_sample[3] * inst.weight
			tilt = tilt + head_sample[4] * inst.weight
		end
	end

	return follow, nod, turn, tilt
end

local head_delta, head_want, head_error, neck_target, head_target = Quat(), Quat(), Quat(), Quat(), Quat()
local neck_rest, neck_now, neck_accum, view_conjugate, accum_conjugate = Quat(), Quat(), Quat(), Quat(), Quat()
local head_offset = Quat()
local NECK_CHAIN = {"neck", "head"}

local function scale_rotation(out, q, t)
	local w, x, y, z = q.w, q.x, q.y, q.z

	if w < 0 then w, x, y, z = -w, -x, -y, -z end

	local sine = math.sqrt(x * x + y * y + z * z)

	if sine < 1e-6 then return out:Set(0, 0, 0, 1) end

	local half = math.atan2(sine, w) * t
	local k = math.sin(half) / sine
	return out:Set(x * k, y * k, z * k, math.cos(half))
end

aim_pose.ScaleRotation = scale_rotation

local function follow_state(pose, key, target, rate, dt, snap)
	local state = pose[key]

	if not state then
		state = Quat(target.x, target.y, target.z, target.w)
		pose[key] = state
		return state
	end

	if snap then
		state:Set(target.x, target.y, target.z, target.w)
	elseif dt > 0 then
		if state:Dot(target) < 0 then
			target:Set(-target.x, -target.y, -target.z, -target.w)
		end

		state:Lerp(math.min(dt * rate, 1), target):Normalize()
	end

	return state
end

local function stabilize_head(bones, pose, aim, follow)
	local shares = aim_pose.Shares
	local view = pose.pitch
	view_conjugate:Set(-view.x, -view.y, -view.z, view.w)
	head_delta:SetMul(aim, view_conjugate)
	scale_rotation(head_error, head_delta, follow)
	head_want:SetMul(head_error, view)
	bones.neck:GetRotation(neck_now)
	neck_accum:SetMul(
		neck_now,
		accum_conjugate:Set(-neck_rest.x, -neck_rest.y, -neck_rest.z, neck_rest.w)
	)
	accum_conjugate:Set(-neck_accum.x, -neck_accum.y, -neck_accum.z, neck_accum.w)
	head_error:SetMul(head_want, accum_conjugate)
	local neck_part = shares.neck / (shares.neck + shares.head)
	scale_rotation(neck_target, head_error, neck_part)
	scale_rotation(head_target, head_error, 1 - neck_part)
	local now = system.GetElapsedTime()
	local dt = 0

	if pose.head_time ~= now then
		dt = math.clamp(now - (pose.head_time or now), 0, 0.1)
		pose.head_time = now
	end

	local snap = not pose.head_stabilized
	pose.head_stabilized = true
	local neck = follow_state(pose, "neck_state", neck_target, aim_pose.HeadLag, dt, snap)
	local head = follow_state(pose, "head_state", head_target, aim_pose.HeadLag * aim_pose.HeadTrail, dt, snap)
	rotation:SetRotation(neck)
	rotate_chain(bones, NECK_CHAIN, 2, bones.neck, rotation)
	rotation:SetRotation(head)
	rotate_chain(bones, HEAD_ONLY, 1, bones.head, rotation)
	pose.head_lag = follow ~= 1 or neck:Dot(neck_target) < 0.99999 or head:Dot(head_target) < 0.99999
end

local apply_hand = {0, 0, 0, 0, 0, 0}
local torso_sample = {0}

function aim_pose.Apply(bones, pose, right, left)
	if right and right:IsTwoHanded() then left = nil end

	local armed = right or left
	local pitch = aim_pose.GetAim(pose, pose.pitch)
	local flinch = 0

	for i = 1, #pose.anims do
		if pose.anims[i].def.TorsoKeys then
			animations.SampleKeys(pose.anims[i].def.TorsoKeys, pose.anims[i].phase, torso_sample, 1)
			flinch = flinch + torso_sample[1] * pose.anims[i].weight * (pose.anims[i].body_scale or 1)
		end
	end

	local head_follow, head_nod, head_turn, head_tilt = aim_pose.GetHead(pose)
	local stabilize = head_follow ~= 1 or pose.head_lag

	if stabilize then
		bones.neck:GetRotation(neck_rest)
	else
		pose.head_stabilized = false
	end

	for _, joint in ipairs(JOINTS) do
		local name = joint[1]
		local share = aim_pose.Shares[name]
		local angle_pitch = pitch

		if flinch ~= 0 and (name == "spine" or name == "chest") then
			angle_pitch = pitch:Copy():RotatePitch(flinch / share)
		end

		if not (stabilize and (name == "neck" or name == "head")) then
			rotation:SetRotation(identity:GetLerped(share, angle_pitch):Normalize())
			rotate_chain(bones, joint[2], #joint[2], bones[name], rotation)
		end
	end

	if not armed then
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

	if stabilize then stabilize_head(bones, pose, pitch, head_follow) end

	if head_nod ~= 0 or head_turn ~= 0 or head_tilt ~= 0 then
		aim_pose.SetWrist(head_offset, head_nod, head_turn, head_tilt)
		rotation:SetRotation(head_offset)
		rotate_chain(bones, HEAD_ONLY, 1, bones.head, rotation)
	end

	local hold_aim = armed and aim_pose.GetHoldAim(pose, aim_pose.GetAim(pose, pose.aim)) or pitch
	aim_pose.GetHand(pose, apply_hand)
	shift_aim:Set(apply_hand[1], apply_hand[2], apply_hand[3])
	Quat.SetVecMul(shift_right, hold_aim, shift_aim)
	shift_aim:Set(-apply_hand[1], apply_hand[2], apply_hand[3])
	Quat.SetVecMul(shift_left, hold_aim, shift_aim)
	aim_pose.SetWrist(hold_roll_right, apply_hand[4], apply_hand[5], apply_hand[6])
	hold_roll_right:SetMul(hold_roll_right, right_roll)
	aim_pose.SetWrist(hold_roll_left, apply_hand[4], -apply_hand[5], -apply_hand[6])

	if right then
		solve_hold(bones, hold_aim, right, RIGHT, 1)
	elseif left then
		solve_neutral(bones, RIGHT, 1)
	end

	local block = animations.GetWeight(pose, "block")

	if block >= 0.999 then
		solve_arm(bones, LEFT, pose.pitch, aim_pose.BlockOffset, aim_pose.BlockReach, -1, ZERO)
	elseif block > 0.001 then
		for i, name in ipairs(LEFT.shoulder_chain) do
			aim_pose.CopyMatrix(left_start[i], bones[name])
		end

		solve_left_hold(bones, hold_aim, right, left)

		for i, name in ipairs(LEFT.shoulder_chain) do
			aim_pose.CopyMatrix(left_hold[i], bones[name])
			aim_pose.CopyMatrix(bones[name], left_start[i])
		end

		solve_arm(bones, LEFT, pose.pitch, aim_pose.BlockOffset, aim_pose.BlockReach, -1, ZERO)

		for i, name in ipairs(LEFT.shoulder_chain) do
			aim_pose.BlendMatrix(bones[name], left_hold[i], bones[name], block)
		end
	else
		solve_left_hold(bones, hold_aim, right, left)
	end
end

return aim_pose
