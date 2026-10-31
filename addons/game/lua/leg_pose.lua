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

local knee_solution = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}

local function solve_reach(bones, leg, target_x, target_y, target_z, flexion)
	local thigh, calf, foot = bones[leg.thigh], bones[leg.calf], bones[leg.foot]
	local upper_length = get_distance(thigh, calf)
	local lower_length = get_distance(calf, foot)
	local tx, ty, tz = thigh.m30, thigh.m31, thigh.m32
	local dx, dy, dz = target_x - tx, target_y - ty, target_z - tz
	local distance = math.max(math.sqrt(dx * dx + dy * dy + dz * dz), 1e-3)
	local fold = math.sqrt(
		upper_length * upper_length + lower_length * lower_length + 2 * upper_length * lower_length * math.cos(flexion)
	)
	local clamped = math.clamp(distance, fold, (upper_length + lower_length) * 0.999)
	local along = (
			upper_length * upper_length - lower_length * lower_length + clamped * clamped
		) / (
			2 * clamped
		)
	local ks = knee_solution
	ks[1], ks[2], ks[3] = tx, ty, tz
	ks[10], ks[11], ks[12] = dx / distance, dy / distance, dz / distance
	ks[13], ks[14] = along, math.sqrt(math.max(upper_length * upper_length - along * along, 0))
	ks[15] = clamped
end

local function solve_knee(bones, leg)
	local ks = knee_solution
	local calf = bones[leg.calf]
	local dx, dy, dz = ks[10], ks[11], ks[12]
	local bx, by, bz, bend

	do
		local kx, ky, kz = calf.m30 - ks[1], calf.m31 - ks[2], calf.m32 - ks[3]
		local pole_along = kx * dx + ky * dy + kz * dz
		bx, by, bz = kx - dx * pole_along, ky - dy * pole_along, kz - dz * pole_along
		bend = math.sqrt(bx * bx + by * by + bz * bz)
	end

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

	local along, height, clamped = ks[13], ks[14], ks[15]
	local tx, ty, tz = ks[1], ks[2], ks[3]
	ks[4], ks[5], ks[6] = tx + dx * along + bx * height,
	ty + dy * along + by * height,
	tz + dz * along + bz * height
	ks[7], ks[8], ks[9] = tx + dx * clamped, ty + dy * clamped, tz + dz * clamped
end

local function solve_bend(bones, leg)
	local ks = knee_solution
	local calf = bones[leg.calf]
	local dx, dy, dz = ks[10], ks[11], ks[12]
	local kx, ky, kz = calf.m30 - ks[1], calf.m31 - ks[2], calf.m32 - ks[3]
	local along = kx * dx + ky * dy + kz * dz
	local bx, by, bz = kx - dx * along, ky - dy * along, kz - dz * along
	local bend = math.sqrt(bx * bx + by * by + bz * bz)

	if bend < 1e-4 then
		bx, by, bz = -dx * dy, 1 - dy * dy, -dz * dy
		bend = math.sqrt(bx * bx + by * by + bz * bz)

		if bend < 1e-4 then bx, by, bz, bend = 0, 0, -1, 1 end
	end

	bx, by, bz = bx / bend, by / bend, bz / bend
	local reach, height, clamped = ks[13], ks[14], ks[15]
	local tx, ty, tz = ks[1], ks[2], ks[3]
	ks[4], ks[5], ks[6] = tx + dx * reach + bx * height,
	ty + dy * reach + by * height,
	tz + dz * reach + bz * height
	ks[7], ks[8], ks[9] = tx + dx * clamped, ty + dy * clamped, tz + dz * clamped
end

local function solve_leg(bones, leg, foot, planted, target_y, normal, solve_pole, flexion)
	local ks = knee_solution
	solve_reach(
		bones,
		leg,
		planted and planted.x or foot.m30,
		target_y,
		planted and planted.z or foot.m32,
		flexion
	)
	solve_pole(bones, leg)
	planted = nil
	target_y = nil
	local thigh, calf = bones[leg.thigh], bones[leg.calf]
	local original = foot:GetRotation()
	aim_pose.SetBetween(
		between,
		calf.m30 - ks[1],
		calf.m31 - ks[2],
		calf.m32 - ks[3],
		ks[4] - ks[1],
		ks[5] - ks[2],
		ks[6] - ks[3]
	)
	rotation:SetRotation(between)
	aim_pose.RotateChain(bones, leg.chain, 3, thigh, rotation)
	aim_pose.SetBetween(
		between,
		foot.m30 - calf.m30,
		foot.m31 - calf.m31,
		foot.m32 - calf.m32,
		ks[7] - ks[4],
		ks[8] - ks[5],
		ks[9] - ks[6]
	)
	rotation:SetRotation(between)
	aim_pose.RotateChain(bones, leg.lower_chain, 2, calf, rotation)
	aim_pose.SetBetween(between, 0, 1, 0, normal.x, normal.y, normal.z)
	local angle = 2 * math.acos(math.clamp(between.w, -1, 1))
	local share = angle > leg_pose.MaxTilt and leg_pose.MaxTilt / angle or 1
	foot:SetRotation(identity:GetLerped(share, between):Normalize() * original)
	foot:SetTranslation(ks[7], ks[8], ks[9])
end

do
	local target = {x = 0, y = 0, z = 0}
	local UP = Vec3(0, 1, 0)

	-- index 1 is the right leg, 2 the left, the target is the ankle in model space
	function leg_pose.SolveFoot(bones, index, x, y, z)
		local leg = LEGS[index]
		target.x, target.y, target.z = x, y, z
		solve_leg(bones, leg, bones[leg.foot], target, y, UP, solve_knee, leg_pose.KneeFlexion)
	end

	leg_pose.LimbFlexion = math.pi * 0.98

	-- a limb of only two bones (upper, lower) reaches with a virtual tip bone, named after the lower one, that the caller places at the sole
	function leg_pose.NewLimb(upper, lower, tip)
		local virtual = tip == nil
		tip = tip or lower .. "#sole"
		return {
			thigh = upper,
			calf = lower,
			foot = tip,
			chain = {upper, lower, tip},
			lower_chain = {lower, tip},
			bones = virtual and {upper, lower} or {upper, lower, tip},
			virtual_matrix = virtual and Matrix44():Identity() or nil,
		}
	end

	-- the point of each tip bone that touches the ground, in the bone's own frame: the lowest vertex of the hull of its physics solid at rest, false when the model has no solid for the bone
	function leg_pose.GetSoles(ragdoll, tips)
		local solids = {}

		for _, solid in ipairs(ragdoll.solids) do
			solids[solid.bone:lower()] = solid
		end

		local soles = {}

		for i, tip in ipairs(tips) do
			local solid = solids[tip:lower()]
			soles[i] = false

			if solid then
				local lowest

				for _, child in ipairs(solid.children) do
					for _, vertex in ipairs(child.ConvexHull.vertices) do
						local local_point = child.Position + vertex
						local height = (solid.bone_position + solid.bone_rotation:VecMul(local_point)).y

						if not lowest or height < lowest then lowest, soles[i] = height, local_point end
					end
				end
			end
		end

		return soles
	end

	-- a limb of any creature: the bend keeps the side the animation gave it, and it may fold far tighter than a knee
	function leg_pose.SolveLimb(bones, limb, x, y, z, normal)
		target.x, target.y, target.z = x, y, z
		solve_leg(
			bones,
			limb,
			bones[limb.foot],
			target,
			y,
			normal,
			solve_bend,
			leg_pose.LimbFlexion
		)
	end
end

leg_pose.FootYawFollow = 0.6
leg_pose.HeadHold = 0.8
local pelvis = {0, 0, 0, 0, 0, 0}
local pelvis_sample = {0, 0, 0, 0, 0, 0}
local pelvis_rotation = Quat()
local pelvis_inverse = Quat()
local foot_yaw = Quat()
local pelvis_matrix = Matrix44()
local FEET = {"foot_r", "foot_l"}
local FOOT_CHAINS = {{"foot_r"}, {"foot_l"}}
local HEAD_CHAINS = {{"neck"}, {"head"}}
local head_hold = Quat()

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
				pelvis[j] = pelvis[j] + pelvis_sample[j] * inst.weight * (inst.body_scale or 1)
			end
		end

		if def.Pelvis then
			def.Pelvis(inst, pose, pelvis_sample)

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

	aim_pose.ScaleRotation(head_hold, pelvis_inverse, leg_pose.HeadHold)
	pelvis_matrix:SetRotation(head_hold)

	for i = 1, 2 do
		aim_pose.RotateChain(bones, HEAD_CHAINS[i], 1, bones[HEAD_CHAINS[i][1]], pelvis_matrix)
	end
end

function leg_pose.Apply(bones, shift_r, shift_l, pelvis_shift, normals, state)
	local active = state and state.active
	local planted_r, planted_l = active and state[1], active and state[2]
	local target_r = (planted_r and planted_r.y or bones.foot_r.m31) + shift_r
	local target_l = (planted_l and planted_l.y or bones.foot_l.m31) + shift_l

	for _, name in ipairs(aim_pose.Bones) do
		bones[name].m31 = bones[name].m31 + pelvis_shift
	end

	solve_leg(
		bones,
		LEGS[1],
		bones.foot_r,
		planted_r,
		target_r,
		normals[1],
		solve_knee,
		leg_pose.KneeFlexion
	)
	solve_leg(
		bones,
		LEGS[2],
		bones.foot_l,
		planted_l,
		target_l,
		normals[2],
		solve_knee,
		leg_pose.KneeFlexion
	)

	if state then state.active = false end
end

return leg_pose
