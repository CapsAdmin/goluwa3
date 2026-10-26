local Matrix44 = import("goluwa/structs/matrix44.lua")
local Quat = import("goluwa/structs/quat.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local aim_pose = import("lua/aim_pose.lua")
local animations = import("lua/animations.lua")
local leg_pose = {}
leg_pose.MaxTilt = math.rad(35)
leg_pose.KneeFlexion = 2.4
leg_pose.KneeForward = 0.8
leg_pose.KneeTrust = 0.05
local LEGS = {
	{
		thigh = "thigh_r",
		calf = "calf_r",
		foot = "foot_r",
		chain = {"thigh_r", "calf_r", "foot_r"},
		lower_chain = {"calf_r", "foot_r"},
	},
	{
		thigh = "thigh_l",
		calf = "calf_l",
		foot = "foot_l",
		chain = {"thigh_l", "calf_l", "foot_l"},
		lower_chain = {"calf_l", "foot_l"},
	},
}
local identity = Quat(0, 0, 0, 1)
local between = Quat()
local rotation = Matrix44()

local function get_distance(a, b)
	return math.sqrt((a.m30 - b.m30) ^ 2 + (a.m31 - b.m31) ^ 2 + (a.m32 - b.m32) ^ 2)
end

local function solve_leg(bones, leg, target_x, target_y, target_z, normal_x, normal_y, normal_z)
	local thigh, calf, foot = bones[leg.thigh], bones[leg.calf], bones[leg.foot]
	local upper_length = get_distance(thigh, calf)
	local lower_length = get_distance(calf, foot)
	local tx, ty, tz = thigh.m30, thigh.m31, thigh.m32
	local dx, dy, dz = target_x - tx, target_y - ty, target_z - tz
	local distance = math.max(math.sqrt(dx * dx + dy * dy + dz * dz), 1e-3)
	local fold = math.sqrt(
		upper_length * upper_length + lower_length * lower_length + 2 * upper_length * lower_length * math.cos(leg_pose.KneeFlexion)
	)
	local clamped = math.clamp(distance, fold, (upper_length + lower_length) * 0.999)
	local along = (
			upper_length * upper_length - lower_length * lower_length + clamped * clamped
		) / (
			2 * clamped
		)
	local height = math.sqrt(math.max(upper_length * upper_length - along * along, 0))
	dx, dy, dz = dx / distance, dy / distance, dz / distance
	local kx, ky, kz = calf.m30 - tx, calf.m31 - ty, calf.m32 - tz
	local pole_along = kx * dx + ky * dy + kz * dz
	local bx, by, bz = kx - dx * pole_along, ky - dy * pole_along, kz - dz * pole_along
	local bend = math.sqrt(bx * bx + by * by + bz * bz)
	local fx, fy, fz = dx * dz, dy * dz, dz * dz - 1
	local forward_length = math.sqrt(fx * fx + fy * fy + fz * fz)

	if forward_length > 1e-4 then
		fx, fy, fz = fx / forward_length, fy / forward_length, fz / forward_length

		if bend < 1e-4 then
			bx, by, bz, bend = fx, fy, fz, 1
		else
			local trust = math.clamp(bend / leg_pose.KneeTrust, 0, 1)
			bx = bx / bend * trust + fx * (1 - trust)
			by = by / bend * trust + fy * (1 - trust)
			bz = bz / bend * trust + fz * (1 - trust)
			bend = math.sqrt(bx * bx + by * by + bz * bz)
		end

		bx, by, bz = bx / bend, by / bend, bz / bend
		local facing = bx * fx + by * fy + bz * fz

		if facing < leg_pose.KneeForward then
			local sx, sy, sz = dy * fz - dz * fy, dz * fx - dx * fz, dx * fy - dy * fx
			local side = bx * sx + by * sy + bz * sz < 0 and -1 or 1
			local rest = math.sqrt(1 - leg_pose.KneeForward * leg_pose.KneeForward)
			bx = fx * leg_pose.KneeForward + sx * side * rest
			by = fy * leg_pose.KneeForward + sy * side * rest
			bz = fz * leg_pose.KneeForward + sz * side * rest
		end
	else
		bx, by, bz = 0, 0, -1
	end

	local knee_x, knee_y, knee_z = tx + dx * along + bx * height,
	ty + dy * along + by * height,
	tz + dz * along + bz * height
	local foot_x, foot_y, foot_z = tx + dx * clamped, ty + dy * clamped, tz + dz * clamped
	local original = foot:GetRotation()
	aim_pose.SetBetween(
		between,
		calf.m30 - tx,
		calf.m31 - ty,
		calf.m32 - tz,
		knee_x - tx,
		knee_y - ty,
		knee_z - tz
	)
	rotation:SetRotation(between)
	aim_pose.RotateChain(bones, leg.chain, 3, thigh, rotation)
	aim_pose.SetBetween(
		between,
		foot.m30 - calf.m30,
		foot.m31 - calf.m31,
		foot.m32 - calf.m32,
		foot_x - knee_x,
		foot_y - knee_y,
		foot_z - knee_z
	)
	rotation:SetRotation(between)
	aim_pose.RotateChain(bones, leg.lower_chain, 2, calf, rotation)
	aim_pose.SetBetween(between, 0, 1, 0, normal_x, normal_y, normal_z)
	local angle = 2 * math.acos(math.clamp(between.w, -1, 1))
	local share = angle > leg_pose.MaxTilt and leg_pose.MaxTilt / angle or 1
	foot:SetRotation(identity:GetLerped(share, between):Normalize() * original)
	foot:SetTranslation(foot_x, foot_y, foot_z)
end

leg_pose.FootYawFollow = 0.6
local pelvis = {0, 0, 0, 0, 0, 0}
local pelvis_sample = {0, 0, 0, 0, 0, 0}
local pelvis_rotation = Quat()
local pelvis_inverse = Quat()
local foot_yaw = Quat()
local pelvis_matrix = Matrix44()
local FEET = {"foot_r", "foot_l"}
local FOOT_CHAINS = {{"foot_r"}, {"foot_l"}}

function leg_pose.NewState()
	return {{x = 0, y = 0, z = 0}, {x = 0, y = 0, z = 0}, active = false}
end

function leg_pose.ApplyKeys(bones, pose, side, state)
	local anims = pose.anims

	for i = 1, 6 do
		pelvis[i] = 0
	end

	for i = 1, #anims do
		local inst = anims[i]
		local def = inst.def

		if def.PelvisKeys then
			animations.SampleKeys(def.PelvisKeys, inst.phase, pelvis_sample, 6)

			for j = 1, 6 do
				pelvis[j] = pelvis[j] + pelvis_sample[j] * inst.weight
			end
		end
	end

	for i = 1, 2 do
		local foot = bones[FEET[i]]
		local planted = state[i]
		planted.x, planted.y, planted.z = foot.m30, foot.m31, foot.m32
	end

	state.active = true
	local body = bones.body
	local all = aim_pose.Bones
	aim_pose.SetWrist(pelvis_rotation, pelvis[5], pelvis[4] * side, pelvis[6] * side)
	pelvis_matrix:SetRotation(pelvis_rotation)
	aim_pose.RotateChain(bones, all, #all, body, pelvis_matrix)

	for i = 1, #all do
		local matrix = bones[all[i]]
		matrix.m30 = matrix.m30 + pelvis[1] * side
		matrix.m31 = matrix.m31 + pelvis[2]
		matrix.m32 = matrix.m32 + pelvis[3]
	end

	pelvis_inverse:Set(-pelvis_rotation.x, -pelvis_rotation.y, -pelvis_rotation.z, pelvis_rotation.w)
	pelvis_matrix:SetRotation(pelvis_inverse)
	local half = pelvis[4] * side * leg_pose.FootYawFollow / 2
	foot_yaw:Set(0, math.sin(half), 0, math.cos(half))

	for i = 1, 2 do
		aim_pose.RotateChain(bones, FOOT_CHAINS[i], 1, bones[FEET[i]], pelvis_matrix)
	end

	pelvis_matrix:SetRotation(foot_yaw)

	for i = 1, 2 do
		aim_pose.RotateChain(bones, FOOT_CHAINS[i], 1, bones[FEET[i]], pelvis_matrix)
	end
end

function leg_pose.Apply(bones, shift_r, shift_l, pelvis_shift, normals, state)
	local foot_r, foot_l = bones.foot_r, bones.foot_l
	local planted_r = state and state.active and state[1]
	local planted_l = state and state.active and state[2]
	local target_r = (planted_r and planted_r.y or foot_r.m31) + shift_r
	local target_l = (planted_l and planted_l.y or foot_l.m31) + shift_l
	local x_r, z_r = planted_r and planted_r.x or foot_r.m30, planted_r and planted_r.z or foot_r.m32
	local x_l, z_l = planted_l and planted_l.x or foot_l.m30, planted_l and planted_l.z or foot_l.m32

	for _, name in ipairs(aim_pose.Bones) do
		bones[name].m31 = bones[name].m31 + pelvis_shift
	end

	solve_leg(bones, LEGS[1], x_r, target_r, z_r, normals[1].x, normals[1].y, normals[1].z)
	solve_leg(bones, LEGS[2], x_l, target_l, z_l, normals[2].x, normals[2].y, normals[2].z)

	if state then state.active = false end
end

return leg_pose
