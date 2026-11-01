local ffi = require("ffi")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local Quat = import("goluwa/structs/quat.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local knockout_pose = {}
knockout_pose.FullSpeed = 5.7
local X, Y, Z = Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1)
local MIN_MASS = 0.006
local SWING_LIMIT = 1.6
local TWIST_LIMIT = 0.5
local CORE_SWING_LIMIT = 0.3
local CORE_PUSH = 0.35
local SNAP_RATE = 8
local SNAP_MIN_MASS = 0.3
local MAX_SNAP = 1
local CORE_TWIST_LIMIT = 0.15
local MAX_ACCELERATION = 60
local MAX_DT = 1 / 30
local MAX_STEP = 1 / 120
local KICK = 1.2
local DRAG = 9
local SLACK = 0.1
local SMOOTHING = 40
local RAMP_RATE = 6
local rotation = Quat()
local velocity = Vec3()

-- a bone weighs what the skin hangs on it and on everything below it, so the core is heavy and the tips of the limbs are light
local function get_masses(rig)
	local skeleton = rig.skeleton
	local masses = skeleton.KnockoutMass

	if masses then return masses end

	local count, parents = skeleton.BoneCount, skeleton.parents
	masses = {}
	local total = 0

	for i = 0, count - 1 do
		masses[i] = 0
	end

	for _, skinned in ipairs(rig.skinned) do
		local indices, weights = skinned.skin.BoneIndices, skinned.skin.BoneWeights

		for i = 0, skinned.count * 4 - 1 do
			local weight = weights[i]

			if weight > 0 then
				masses[indices[i]] = masses[indices[i]] + weight
				total = total + weight
			end
		end
	end

	for i = count - 1, 0, -1 do
		local parent = parents[i]

		if parent >= 0 then masses[parent] = masses[parent] + masses[i] end
	end

	for i = 0, count - 1 do
		masses[i] = total > 0 and math.min(masses[i] / total, 1) or 0
	end

	skeleton.KnockoutMass = masses
	return masses
end

local function hash(index, axis)
	local value = math.sin(index * 12.9898 + axis * 78.233) * 43758.5453
	return (value - math.floor(value)) * 2 - 1
end

function knockout_pose.New()
	return {
		time = 0,
		speed = 0,
		entries = nil,
		position = nil,
		velocity = Vec3(),
		acceleration = Vec3(),
		shift = Vec3(),
	}
end

function knockout_pose.GetFactor(speed, time)
	return math.min(speed / knockout_pose.FullSpeed, 1) * math.min(time * RAMP_RATE, 1)
end

function knockout_pose.Drive(state, rig, animator, position, entity_rotation, dt, dead, ground, margin)
	if rig.held then return end

	if state.entries and (state.rig ~= rig or animator.clip) then
		state.entries = nil
	end

	local entries = state.entries

	if not entries then
		entries = {}
		state.entries = entries
		state.rig = rig
		rig:ClearBones()
		local skeleton = rig.skeleton
		local pose_data, bind = rig.pose.data, skeleton.BindLocal

		-- the animation carries the facing of the model on its root bones, the bind pose of a source rig faces a quarter turn off
		for index = 0, skeleton.BoneCount - 1 do
			if skeleton.parents[index] >= 0 then
				ffi.copy(pose_data + index * 7, bind + index * 7, 28)
			end
		end

		rig.dirty = true
		animator.clip = nil
		animator.clip_dirty = false
		animator.fade = nil
		animator.dirty = false
		local names, parents = skeleton.BoneNames, skeleton.parents
		local masses = get_masses(rig)
		state.roots = {}
		state.core_bones = {}

		for index = 0, skeleton.BoneCount - 1 do
			if parents[index] < 0 then
				local p = index * 7
				state.roots[#state.roots + 1] = {
					name = names[index + 1],
					inverse = Quat(pose_data[p + 3], pose_data[p + 4], pose_data[p + 5], pose_data[p + 6]):GetConjugated(),
					matrix = Matrix44():Identity(),
				}
			end

			if masses[index] >= SNAP_MIN_MASS then
				state.core_bones[#state.core_bones + 1] = index * 12
			end
		end

		for index = 0, skeleton.BoneCount - 1 do
			local mass = masses[index]

			if parents[index] >= 0 and mass >= MIN_MASS then
				local world = rig:GetBone(names[index + 1])
				local heaviest, best = nil, -1

				for child = 0, skeleton.BoneCount - 1 do
					if parents[child] == index and masses[child] > best then
						heaviest, best = child, masses[child]
					end
				end

				local direction
				local axis_x = Vec3(world.m00, world.m01, world.m02)
				local axis_y = Vec3(world.m10, world.m11, world.m12)
				local axis_z = Vec3(world.m20, world.m21, world.m22)
				local twist = 1

				if heaviest then
					local child_world = rig:GetBone(names[heaviest + 1])
					direction = Vec3(
						child_world.m30 - world.m30,
						child_world.m31 - world.m31,
						child_world.m32 - world.m32
					)

					if direction:GetLength() > 1e-4 then
						direction = direction:GetNormalized()
						local along = {
							math.abs(direction:Dot(axis_x)),
							math.abs(direction:Dot(axis_y)),
							math.abs(direction:Dot(axis_z)),
						}
						twist = along[2] > along[1] and 2 or 1

						if along[3] > along[twist] then twist = 3 end
					else
						direction = nil
					end
				end

				local lightness = 1 - mass
				local swing = SWING_LIMIT + (CORE_SWING_LIMIT - SWING_LIMIT) * mass
				local twist_limit = TWIST_LIMIT + (CORE_TWIST_LIMIT - TWIST_LIMIT) * mass
				entries[#entries + 1] = {
					name = names[index + 1],
					frequency = 6 + 14 * mass ^ 0.7,
					damping = 0.35 + 0.6 * mass ^ 0.5,
					kick = KICK * (CORE_PUSH + (1 - CORE_PUSH) * lightness),
					drag = DRAG * (CORE_PUSH + (1 - CORE_PUSH) * lightness),
					slack = {
						hash(index, 1) * SLACK * lightness,
						hash(index, 2) * SLACK * lightness,
						hash(index, 3) * SLACK * lightness,
					},
					angle = {0, 0, 0},
					speed = {0, 0, 0},
					limits = {
						twist == 1 and twist_limit or swing,
						twist == 2 and twist_limit or swing,
						twist == 3 and twist_limit or swing,
					},
					index = index,
					child = direction and heaviest,
					matrix = Matrix44():Identity(),
				}
			end
		end
	end

	if state.position and dt > 0 then
		local previous = state.velocity
		velocity:Set(
			(position.x - state.position.x) / dt,
			(position.y - state.position.y) / dt,
			(position.z - state.position.z) / dt
		)
		local blend = math.min(dt * SMOOTHING, 1)
		local smoothed = state.acceleration
		smoothed:Set(
			smoothed.x + ((velocity.x - previous.x) / dt - smoothed.x) * blend,
			smoothed.y + ((velocity.y - previous.y) / dt - smoothed.y) * blend,
			smoothed.z + ((velocity.z - previous.z) / dt - smoothed.z) * blend
		)
		previous:Set(
			previous.x + (velocity.x - previous.x) * blend,
			previous.y + (velocity.y - previous.y) * blend,
			previous.z + (velocity.z - previous.z) * blend
		)
		state.speed = previous:GetLength()
	end

	animator.dirty = false
	state.position = position:Copy()
	state.time = state.time + dt
	local ramp = math.min(state.time * RAMP_RATE, 1)
	local inverse = entity_rotation:GetConjugated()
	local acceleration = inverse:VecMul(state.acceleration)
	local length = acceleration:GetLength()

	if length > MAX_ACCELERATION then
		acceleration = acceleration * (MAX_ACCELERATION / length)
	end

	local travel = inverse:VecMul(state.velocity)
	local slack = dead and ramp or 0
	local step_time = math.min(dt, MAX_DT)
	local steps = math.ceil(step_time / MAX_STEP)
	local step = steps > 0 and step_time / steps or 0
	local world = rig.world
	local shift = state.shift
	local rx, ry, rz = 2 * (
			entity_rotation.x * entity_rotation.y - entity_rotation.w * entity_rotation.z
		),
	1 - 2 * (
			entity_rotation.x * entity_rotation.x + entity_rotation.z * entity_rotation.z
		),
	2 * (
			entity_rotation.y * entity_rotation.z + entity_rotation.w * entity_rotation.x
		)
	local target_x, target_y, target_z = 0, 0, 0

	if ground then
		local lowest = math.huge

		for _, o in ipairs(state.core_bones) do
			local height = rx * (
					world[o + 3] - shift.x
				) + ry * (
					world[o + 7] - shift.y
				) + rz * (
					world[o + 11] - shift.z
				)

			if height < lowest then lowest = height end
		end

		local lift = math.clamp(ground - (position.y + lowest - margin), -MAX_SNAP, MAX_SNAP)
		target_x, target_y, target_z = rx * lift, ry * lift, rz * lift
	end

	local blend = math.min(dt * SNAP_RATE, 1)
	shift:Set(
		shift.x + (target_x - shift.x) * blend,
		shift.y + (target_y - shift.y) * blend,
		shift.z + (target_z - shift.z) * blend
	)

	for _, root in ipairs(state.roots) do
		local local_shift = root.inverse:VecMul(shift)
		root.matrix:SetTranslation(local_shift.x, local_shift.y, local_shift.z)
		rig:SetBone(root.name, root.matrix, "local")
	end

	for _, entry in ipairs(entries) do
		local angle, speed, limits, rest = entry.angle, entry.speed, entry.limits, entry.slack
		local push_x, push_y, push_z = 0, 0, 0

		if entry.child then
			local o, c = entry.index * 12, entry.child * 12
			local dx, dy, dz = world[c + 3] - world[o + 3],
			world[c + 7] - world[o + 7],
			world[c + 11] - world[o + 11]
			local reach = math.sqrt(dx * dx + dy * dy + dz * dz)

			if reach > 1e-5 then
				dx, dy, dz = dx / reach, dy / reach, dz / reach
				local fx = -acceleration.x * entry.kick - travel.x * entry.drag * ramp
				local fy = -acceleration.y * entry.kick - travel.y * entry.drag * ramp
				local fz = -acceleration.z * entry.kick - travel.z * entry.drag * ramp
				local torque_x, torque_y, torque_z = dy * fz - dz * fy, dz * fx - dx * fz, dx * fy - dy * fx
				-- the push is turned into the axes the bone had before its own override, which is what the override is applied in
				local row_x = torque_x * world[o] + torque_y * world[o + 4] + torque_z * world[o + 8]
				local row_y = torque_x * world[o + 1] + torque_y * world[o + 5] + torque_z * world[o + 9]
				local row_z = torque_x * world[o + 2] + torque_y * world[o + 6] + torque_z * world[o + 10]
				local q = entry.matrix
				push_x = q.m00 * row_x + q.m10 * row_y + q.m20 * row_z
				push_y = q.m01 * row_x + q.m11 * row_y + q.m21 * row_z
				push_z = q.m02 * row_x + q.m12 * row_y + q.m22 * row_z
			end
		end

		local frequency, damping = entry.frequency, entry.damping
		local stiffness, brake = frequency * frequency, 2 * damping * frequency

		for _ = 1, steps do
			for axis = 1, 3 do
				local push = axis == 1 and push_x or axis == 2 and push_y or push_z
				speed[axis] = speed[axis] + (
						stiffness * (
							rest[axis] * slack - angle[axis]
						) - brake * speed[axis] + push
					) * step
				local value = angle[axis] + speed[axis] * step
				local limit = limits[axis]

				if value < -limit then
					value = -limit
					speed[axis] = 0
				elseif value > limit then
					value = limit
					speed[axis] = 0
				end

				angle[axis] = value
			end
		end

		Quat.SetMul(rotation, QuatFromAxis(angle[2], Y), QuatFromAxis(angle[1], X))
		Quat.SetMul(rotation, rotation, QuatFromAxis(angle[3], Z))
		entry.matrix:Identity()
		entry.matrix:SetRotation(rotation)
		rig:SetBone(entry.name, entry.matrix, "local")
	end

	rig:Compute()
end

function knockout_pose.Release(state, rig, animator)
	animator.clip_dirty = true
	animator.dirty = true

	for _, entry in ipairs(state.entries or {}) do
		rig:ClearBone(entry.name)
	end

	for _, root in ipairs(state.roots or {}) do
		rig:ClearBone(root.name)
	end

	rig:Compute()
end

return knockout_pose
