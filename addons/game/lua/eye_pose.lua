local Matrix44 = import("goluwa/structs/matrix44.lua")
local Quat = import("goluwa/structs/quat.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local physics = import("goluwa/physics.lua")
local aim_pose = import("lua/aim_pose.lua")
local pose_variation = import("lua/pose_variation.lua")
local UNIT = import("goluwa/source_engine/units.lua").meters
local FORWARD = import("goluwa/render3d/orientation.lua").FORWARD_VECTOR
local eye_pose = {}
eye_pose.EyeRadius = 16 * UNIT
eye_pose.BodyDrop = 8 * UNIT
eye_pose.EyeHeight = 64 * UNIT
eye_pose.CrouchEyeHeight = 28 * UNIT
eye_pose.ArmLength = 38 * UNIT
eye_pose.LegLength = 50 * UNIT
eye_pose.FootHeight = 2.5 * UNIT
eye_pose.FootSink = 1 * UNIT
eye_pose.GroundBound = 12 * UNIT
eye_pose.LimbRadius = 1.5 * UNIT
eye_pose.Grips = {
	weapon_pistol = {right = Vec3(0, -0.07, -0.16)},
	weapon_physgun = {right = Vec3(0, -0.09, -0.16), left = Vec3(0, -0.07, -0.38)},
	weapon_camera = {right = Vec3(0.11, -0.01, -0.22), left = Vec3(-0.11, -0.01, -0.22)},
}
eye_pose.DefaultGrip = {right = Vec3(0, 0, 0)}
eye_pose.BlockGrip = Vec3(-0.05, 0.08, -0.28)
local EYE_RADIUS = eye_pose.EyeRadius
local ARM_LENGTH = eye_pose.ArmLength
local LEG_LENGTH = eye_pose.LegLength
local FOOT_HEIGHT = eye_pose.FootHeight
local FOOT_SINK = eye_pose.FootSink
local GROUND_BOUND = eye_pose.GroundBound
local HEIGHT = 72 * UNIT
local CROUCH_HEIGHT = 36 * UNIT
local WEAPON_FORWARD = 0.12
local WEAPON_RAISE = 0.12
local EYE_HOLD_BACK = 0.14
local STEP_TIME = 0.2
local STEP_LIFT = 4 * UNIT
local UP = Vec3(0, 1, 0)
local DOWN = Vec3(0, -1, 0)
local ZERO = Vec3(0, 0, 0)
local scratch = Quat()
local torso = Quat()
local tilt = Quat()
local tilted_torso = Quat()
local WEAPON_OFFSET = Vec3(0.2, -0.22, -0.15)
local TORSO_PITCH = 0.35
local HIP_OFFSET = Vec3(0.4 * EYE_RADIUS, -0.4 * EYE_RADIUS, 0.2 * EYE_RADIUS)
local BODY_DROP = eye_pose.BodyDrop

local function solve(root, target, length_a, length_b, pole)
	local delta = target - root
	local length = delta:GetLength()
	local direction = length > 1e-5 and delta / length or Vec3(0, -1, 0)
	local dist = math.clamp(length, 1e-3, (length_a + length_b) * 0.999)
	local along = (length_a * length_a - length_b * length_b + dist * dist) / (2 * dist)
	local height = math.sqrt(math.max(length_a * length_a - along * along, 0))
	local bend = (pole - direction * pole:Dot(direction)):GetNormalized()
	return root + direction * along + bend * height, root + direction * dist
end

local function write(matrix, position, rotation)
	matrix:Identity()
	matrix:SetRotation(rotation)
	matrix:SetTranslation(position.x, position.y, position.z)
end

local function write_limb(matrix, from, to)
	aim_pose.SetBetween(scratch, 0, 1, 0, to.x - from.x, to.y - from.y, to.z - from.z)
	write(matrix, from, scratch)
end

local function ground_foot(foot, owner)
	local plane = foot.y - FOOT_HEIGHT
	local hit = physics.instance and
		physics.RayCast(Vec3(foot.x, plane + GROUND_BOUND, foot.z), DOWN, GROUND_BOUND * 2, owner)
	foot.y = (hit and hit.position.y or plane) + FOOT_HEIGHT - FOOT_SINK
	return foot
end

function eye_pose.New()
	return {
		velocity = Vec3(0, 0, 0),
		roll = 0,
		phase = 0,
		sides = {{name = "l", sign = -1}, {name = "r", sign = 1}},
	}
end

function eye_pose.Compute(state, bones, owner, dt)
	local pose = owner.character_pose
	local transform = owner.transform
	local view = pose.pitch
	local aim = aim_pose.GetAim(pose)
	local crouch = pose.crouch_alpha
	local body = owner.rigid_body
	local _, render_rotation = transform:GetRenderPositionRotation()
	local velocity = (
		render_rotation or
		transform:GetRotation()
	):GetConjugated():VecMul(body and body:GetVelocity() or transform:GetRenderVelocity())
	local grounded = not body or pose.grounded
	local holder = owner.weapon_holder
	local active = holder and holder:GetActiveWeapon()
	local eye_height = math.lerp(crouch, eye_pose.EyeHeight, eye_pose.CrouchEyeHeight)
	local grips, hold
	local blocking = pose.block_alpha > 0.5

	if active then
		grips = eye_pose.Grips[active.prefab.Path] or eye_pose.DefaultGrip
		local forward = aim:GetForward()

		if active.weapon:IsHeldAtEye() then
			hold = Vec3(0, eye_height, 0) - forward * EYE_HOLD_BACK
		else
			hold = Vec3(0, eye_height, 0) + aim:VecMul(WEAPON_OFFSET)
		end
	end

	if blocking and not hold then
		hold = Vec3(0, math.lerp(crouch, HEIGHT, CROUCH_HEIGHT) * 0.5 + WEAPON_RAISE, 0) + view:GetForward() * WEAPON_FORWARD
	end

	local smoothed = state.velocity
	smoothed = smoothed + (Vec3(velocity.x, 0, velocity.z) - smoothed) * math.min(dt * 6, 1)
	state.velocity = smoothed
	local speed = smoothed:GetLength()
	state.roll = state.roll + (
			math.clamp(-smoothed.x * 0.12, -0.6, 0.6) - state.roll
		) * math.min(dt * 6, 1)
	state.phase = pose.Distance * 1.5 + pose.seed * math.pi * 2
	local look = view:GetForward()
	local lean = (look + smoothed * 0.05):GetNormalized()
	aim_pose.SetBetween(scratch, look.x, look.y, look.z, lean.x, lean.y, lean.z)
	pose_variation.GetLean(tilt, pose.lean_side, pose.lean_forward)
	local rotation = tilt * QuatFromAxis(state.roll, lean) * scratch * view
	torso:Identity():RotatePitch(math.asin(math.clamp(look.y, -1, 1)) * TORSO_PITCH)
	tilted_torso:SetMul(tilt, torso)
	local upright = Vec3(0, eye_height - BODY_DROP, 0) - FORWARD * EYE_RADIUS
	local center = tilt:VecMul(upright)
	local pupil = center + lean * EYE_RADIUS
	write(bones.root, ZERO, scratch:Identity())
	write(bones.neck, center, rotation)
	write(bones.body, center, rotation)
	write(bones.spine, center, rotation)
	write(bones.chest, center, rotation)
	write(bones.head, pupil, aim)
	local world = transform:GetWorldMatrix()
	local world_inverse = transform:GetWorldMatrixInverse()
	local move_dir = speed > 0.1 and smoothed / speed or ZERO
	local knee_pole = Vec3(lean.x, 0, lean.z)
	local foot_yaw = QuatFromAxis(math.atan2(-lean.x, -lean.z), UP)
	local step_duration = math.max(0.1, 0.22 - speed * 0.015)
	local lead = smoothed * (step_duration * 0.5)
	local trigger = 0.35 * EYE_RADIUS + lead:GetLength() * 1.6
	local swing_amount = math.min(speed / 3, 1) * ARM_LENGTH * 0.7

	if knee_pole:GetLength() < 1e-3 then knee_pole = Vec3(0, 0, -1) end

	for i = 1, 2 do
		local side = state.sides[i]
		local sign = side.sign
		local name = side.name
		local shoulder = tilt:VecMul(upright + torso:VecMul(Vec3(sign * 0.85 * EYE_RADIUS, 0, 0.1 * EYE_RADIUS)))
		local hip = tilt:VecMul(upright + Vec3(sign * HIP_OFFSET.x, HIP_OFFSET.y, HIP_OFFSET.z))
		local hang = (
			tilted_torso:VecMul(Vec3(sign * 0.7, -0.5, 0.3)) + Vec3(sign * 0.35, -0.9, 0.1)
		):GetNormalized()
		local grip = grips and (sign == 1 and grips.right or grips.left)

		if blocking and sign == -1 then grip = eye_pose.BlockGrip end

		local target
		local follow = 14

		if grip then
			target = hold + aim:VecMul(grip)
			follow = sign == 1 and 1e6 or 40
		else
			target = shoulder + hang * (
					ARM_LENGTH * 0.85
				) + move_dir * (
					math.sin(state.phase) * -sign * swing_amount
				)
		end

		side.hand = side.hand and
			side.hand + (
				target - side.hand
			) * math.min(dt * follow, 1)
			or
			target
		local elbow, hand = solve(
			shoulder,
			side.hand,
			ARM_LENGTH * 0.5,
			ARM_LENGTH * 0.5,
			tilted_torso:VecMul(Vec3(sign * 0.6, -0.7, 0.4))
		)
		write(bones["clavicle_" .. name], shoulder, rotation)
		write_limb(bones["upperarm_" .. name], shoulder, elbow)
		write_limb(bones["forearm_" .. name], elbow, hand)

		if grip then
			write(bones["hand_" .. name], hand, aim)
		else
			write_limb(bones["hand_" .. name], hand, hand + hand - elbow)
		end

		local home_local = Vec3(sign * 0.55 * EYE_RADIUS, FOOT_HEIGHT, 0.2 * EYE_RADIUS)
		local home = world:TransformVector(home_local)
		local target_foot = world:TransformVector(home_local + lead)
		local foot

		if not grounded then
			side.planted = world:TransformVector(home_local - smoothed * 0.08)
			side.step_time = nil
			foot = side.planted
		elseif not side.planted or (side.planted - home):GetLength() > LEG_LENGTH * 2 then
			side.planted = ground_foot(target_foot, owner)
			side.step_time = nil
			foot = side.planted
		elseif side.step_time then
			side.step_time = side.step_time + dt / step_duration

			if side.step_time >= 1 then
				side.planted = ground_foot(target_foot, owner)
				side.step_time = nil
				foot = side.planted
			else
				ground_foot(target_foot, owner)
				local t = side.step_time * side.step_time * (3 - 2 * side.step_time)
				foot = side.step_from + (target_foot - side.step_from) * t
				foot.y = foot.y + math.sin(side.step_time * math.pi) * STEP_LIFT
			end
		else
			foot = side.planted
			local gap = math.sqrt((foot.x - target_foot.x) ^ 2 + (foot.z - target_foot.z) ^ 2)
			local other = state.sides[3 - i]

			if gap > trigger and (not other.step_time or gap > trigger * 1.5) then
				side.step_from = foot
				side.step_time = 0
			end
		end

		local knee, ankle = solve(
			hip,
			world_inverse:TransformVector(foot),
			LEG_LENGTH * 0.5,
			LEG_LENGTH * 0.5,
			knee_pole
		)
		write_limb(bones["thigh_" .. name], hip, knee)
		write_limb(bones["calf_" .. name], knee, ankle)
		write(bones["foot_" .. name], ankle, foot_yaw)
	end
end

return eye_pose
