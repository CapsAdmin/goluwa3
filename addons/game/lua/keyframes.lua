local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local animations = import("lua/animations.lua")
local aim_pose = import("lua/aim_pose.lua")
local keyframes = {}
keyframes.Tracks = {
	{
		Name = "aim",
		Key = "AimKeys",
		Rest = {0, 0},
		Labels = {"yaw", "pitch"},
		Radians = {1, 2},
	},
	{
		Name = "hand",
		Key = "HandKeys",
		Rest = {0, 0, 0, 0, 0, 0},
		Labels = {"x", "y", "z", "pitch", "yaw", "roll"},
		Radians = {4, 5, 6},
	},
	{
		Name = "torso",
		Key = "TorsoKeys",
		Rest = {0},
		Labels = {"pitch"},
		Radians = {1},
	},
	{
		Name = "head",
		Key = "HeadKeys",
		Rest = {1, 0, 0, 0},
		Labels = {"follow", "nod", "turn", "tilt"},
		Radians = {2, 3, 4},
	},
	{
		Name = "pelvis",
		Key = "PelvisKeys",
		Rest = {0, 0, 0, 0, 0, 0},
		Labels = {"x", "y", "z", "yaw", "pitch", "roll"},
		Radians = {4, 5, 6},
	},
	{
		Name = "body",
		Key = "BodyKeys",
		Rest = {0, 0, 0, 0, 0, 0, 0, 0.95, 0},
		Labels = {"x", "y", "z", "yaw", "pitch", "roll", "pivot x", "pivot y", "pivot z"},
		Radians = {4, 5, 6},
	},
	{
		Name = "motion",
		Key = "MotionKeys",
		Rest = {0, 0, 0},
		Labels = {"orbit", "distance", "blend"},
		Degrees = {1},
		Extend = true,
	},
	{
		Name = "carry",
		Key = "CarryKeys",
		Rest = {0, 0, 0, 0, 0, 0, 0, 0, 0},
		Labels = {"rx", "ry", "rz", "lx", "ly", "lz", "pitch", "yaw", "roll"},
		Radians = {7, 8, 9},
	},
	{Name = "grip", Key = "GripKeys", Rest = {0}, Labels = {"weight"}},
	{Name = "attach", Key = "AttachKeys", Rest = {1}, Labels = {"weight"}},
}
keyframes.Poses = {rest = {}}

for _, track in ipairs(keyframes.Tracks) do
	keyframes.Poses.rest[track.Name] = track.Rest
end

keyframes.FaceIn = 0.12
keyframes.FaceOut = 0.2
local AIRBORNE_LIFT = 0.15
local AIRBORNE_TILT = 0.3

function keyframes.AddPoses(poses)
	for name, pose in pairs(poses) do
		keyframes.Poses[name] = pose
	end
end

local function resolve_pose(name, poses)
	local pose = poses and poses[name] or keyframes.Poses[name]
	assert(pose, "unknown pose " .. name)

	if not pose.base then return pose end

	local merged = table.shallow_copy(resolve_pose(pose.base, poses))

	for key, value in pairs(pose) do
		if key ~= "base" then merged[key] = value end
	end

	return merged
end

keyframes.ResolvePose = resolve_pose

local function to_values(track, value)
	if type(value) == "number" then return {value} end

	assert(#value <= #track.Rest, track.Name .. " has at most " .. #track.Rest .. " values")
	return value
end

local function add_key(rows, t, values, ease, track)
	local row = {t, ease = ease}
	local rest = track.Rest

	for i = 1, #rest do
		row[i + 1] = values[i] == nil and rest[i] or values[i]
	end

	for _, i in ipairs(track.Degrees or {}) do
		row[i + 1] = math.rad(row[i + 1])
	end

	if rows[#rows] and rows[#rows][1] >= t then
		error(
			string.format("keyframes must be in increasing time, %s after %s", t, rows[#rows][1]),
			3
		)
	end

	rows[#rows + 1] = row
end

local function expand(frames, poses)
	local expanded = {}

	for _, frame in ipairs(frames) do
		local pose = type(frame[2]) == "string" and resolve_pose(frame[2], poses) or nil
		local entry = {t = frame[1], ease = frame.ease, values = {}}

		for _, track in ipairs(keyframes.Tracks) do
			local value = frame[track.Name]

			if value == nil and pose then value = pose[track.Name] end

			if value ~= nil then entry.values[track.Name] = to_values(track, value) end
		end

		expanded[#expanded + 1] = entry

		if frame.hold then
			expanded[#expanded + 1] = {t = frame[1] + frame.hold, values = entry.values}
		end
	end

	return expanded
end

local function is_rest(rows, rest)
	for _, row in ipairs(rows) do
		for i, v in ipairs(rest) do
			if (row[i + 1] or 0) ~= v then return false end
		end
	end

	return true
end

local function is_airborne(rows)
	for _, row in ipairs(rows) do
		if
			(
				row[3] or
				0
			) > AIRBORNE_LIFT or
			math.abs(row[6] or 0) > AIRBORNE_TILT or
			math.abs(row[7] or 0) > AIRBORNE_TILT
		then
			return true
		end
	end

	return false
end

do
	local sample = {0, 0, 0, 0, 0, 0, 0, 0, 0}
	local faced = Quat()
	local turn = Quat()
	local pivot = Vec3()
	local offset = Vec3()

	local function face(inst, pose, position, rotation)
		local point = pose:GetFacingPoint()

		if not point then return end

		local f = inst.phase
		local blend = math.min(f / keyframes.FaceIn, (1 - f) / keyframes.FaceOut, 1)
		blend = blend * blend * (3 - 2 * blend) * inst.weight
		local forward = rotation:GetForward()
		local dx, dz = point.x - position.x, point.z - position.z

		if dx * dx + dz * dz < 1e-4 then return end

		local delta = math.normalizeangle(math.atan2(-dx, -dz) - math.atan2(-forward.x, -forward.z))
		turn:Identity():RotateYaw(delta * blend)
		faced:SetMul(turn, rotation)
		rotation:Set(faced.x, faced.y, faced.z, faced.w)
	end

	local function apply_body_keys(keys, phase, weight, position, rotation)
		animations.SampleKeys(keys, phase, sample, 9)
		faced:Set(rotation.x, rotation.y, rotation.z, rotation.w)
		turn:Set(rotation.x, rotation.y, rotation.z, rotation.w)
		turn:RotateYaw(sample[4] * weight):RotatePitch(sample[5] * weight):RotateRoll(sample[6] * weight)
		pivot:Set(sample[7], sample[8], sample[9])
		offset:Set(sample[1] * weight, sample[2] * weight, sample[3] * weight)
		local moved = position + faced:VecMul(offset) + faced:VecMul(pivot) - turn:VecMul(pivot)
		position:Set(moved.x, moved.y, moved.z)
		rotation:Set(turn.x, turn.y, turn.z, turn.w)
	end

	function keyframes.ApplyBody(inst, pose, position, rotation)
		local def = inst.def

		if def.Face then face(inst, pose, position, rotation) end

		if def.BodyKeys then
			apply_body_keys(def.BodyKeys, inst.phase, inst.weight, position, rotation)
		end
	end

	function keyframes.EvaluateBody(def, phase, position, rotation)
		position:Set(0, 0, 0)
		rotation:Set(0, 0, 0, 1)

		if def.BodyKeys then
			apply_body_keys(def.BodyKeys, phase, 1, position, rotation)
		end

		return position, rotation
	end
end

do
	local sample = {0, 0, 0, 0, 0, 0, 0, 0, 0}
	local angles = Vec3()
	local rotated = Vec3()
	local middle = Vec3()

	function keyframes.EvaluateCarry(def, phase, victim_bones, offset, rotation)
		animations.SampleKeys(def.CarryKeys, phase, sample, 9)
		rotation:SetAngles(angles:Set(sample[7], sample[8], sample[9]))
		local right, left = victim_bones[def.CarryBones[1]], victim_bones[def.CarryBones[2]]
		rotated:CopyFrom(
			rotation:VecMul(
				middle:Set((right.m30 + left.m30) / 2, (right.m31 + left.m31) / 2, (right.m32 + left.m32) / 2)
			)
		)
		return offset:Set(
			(sample[1] + sample[4]) / 2 - rotated.x,
			(sample[2] + sample[5]) / 2 - rotated.y,
			(sample[3] + sample[6]) / 2 - rotated.z
		),
		rotation
	end

	local body_position, body_rotation = Vec3(), Quat()
	local hold_offset, hold_rotation = Vec3(), Quat()

	function keyframes.EvaluateVictim(def, phase, victim_bones, position, rotation)
		keyframes.EvaluateBody(def, phase, body_position, body_rotation)
		keyframes.EvaluateCarry(def, phase, victim_bones, hold_offset, hold_rotation)
		local moved = body_position + body_rotation:VecMul(hold_offset)
		position:Set(moved.x, moved.y, moved.z)
		Quat.SetMul(rotation, body_rotation, hold_rotation)
		return position, rotation
	end

	local attach = {1}

	function keyframes.EvaluateAttach(def, phase)
		if not def.AttachKeys then return 1 end

		animations.SampleKeys(def.AttachKeys, phase, attach, 1)
		return attach[1]
	end

	local WINDOW = 0.02
	local before, after = Vec3(), Vec3()
	local ignored = Quat()

	function keyframes.EvaluateVictimVelocity(def, phase, duration, victim_bones, out)
		local from, to = math.max(phase - WINDOW, 0), phase
		keyframes.EvaluateVictim(def, from, victim_bones, before, ignored)
		keyframes.EvaluateVictim(def, to, victim_bones, after, ignored)
		local scale = 1 / ((to - from) * duration)
		return out:Set(
			(after.x - before.x) * scale,
			(after.y - before.y) * scale,
			(after.z - before.z) * scale
		)
	end
end

do
	local ARM_CHAINS = {{"upperarm_r", "forearm_r", "hand_r"}, {"upperarm_l", "forearm_l", "hand_l"}}
	local SIDES = {1, -1}
	local saved = {{}, {}}

	for i = 1, 2 do
		for j = 1, 3 do
			saved[i][j] = Matrix44():Identity()
		end
	end

	local grip = {0}
	local offset, rotation = Vec3(), Quat()
	local point = Vec3()
	local targets = {Vec3(), Vec3()}
	local hand_rotation = Quat(0, 0, 0, 1)

	function keyframes.ApplyGrip(bones, inst, pose)
		local latch = pose.grab_latch

		if not latch then return end

		local def = inst.def
		animations.SampleKeys(def.GripKeys, inst.phase, grip, 1)
		local weight = grip[1] * inst.weight

		if weight < 0.001 then return end

		local victim_bones = latch.Bones

		if keyframes.EvaluateAttach(def, inst.phase) < 1 then
			for i = 1, 2 do
				latch:GetBoneTarget(victim_bones[def.CarryBones[i]], targets[i])
			end
		else
			keyframes.EvaluateCarry(def, inst.phase, victim_bones, offset, rotation)

			for i = 1, 2 do
				local anchor = victim_bones[def.CarryBones[i]]
				point:Set(anchor.m30, anchor.m31, anchor.m32)
				targets[i]:CopyFrom(offset + rotation:VecMul(point))
			end
		end

		for i, side in ipairs(SIDES) do
			local chain = ARM_CHAINS[i]

			for j = 1, 3 do
				aim_pose.CopyMatrix(saved[i][j], bones[chain[j]])
			end

			aim_pose.SolveGrip(bones, side, targets[i], hand_rotation)

			if weight < 0.999 then
				for j = 1, 3 do
					aim_pose.BlendMatrix(bones[chain[j]], saved[i][j], bones[chain[j]], weight)
				end
			end
		end
	end
end

function keyframes.Compile(def, poses)
	def.Kind = def.Kind or "action"
	local frames = expand(def.Keys or {}, poses)

	for _, track in ipairs(keyframes.Tracks) do
		local rows = {}

		for _, frame in ipairs(frames) do
			local values = frame.values[track.Name]

			if values then
				if not rows[1] and frame.t > 0 then
					add_key(rows, 0, track.Rest, nil, track)
				end

				add_key(
					rows,
					frame.t,
					values,
					type(frame.ease) == "table" and frame.ease[track.Name] or frame.ease,
					track
				)
			end
		end

		if rows[1] and not is_rest(rows, track.Rest) then
			if rows[#rows][1] < 1 and not track.Extend then
				add_key(rows, 1, track.Rest, nil, track)
			end

			def[track.Key] = rows
		end
	end

	if def.BodyKeys and def.Legs == nil and is_airborne(def.BodyKeys) then
		def.Legs = false
	end

	if def.BodyKeys or def.Face then def.Body = keyframes.ApplyBody end

	if def.CarryKeys then
		assert(
			def.CarryBones,
			"carry keys place the victim bones named in CarryBones {right, left} at points in the body frame"
		)
	end

	if def.AttachKeys then
		assert(
			def.CarryKeys,
			"attach keys blend the victim between where the latch found it and the carry frame, and need carry keys"
		)
	end

	if def.GripKeys then
		assert(
			def.CarryKeys,
			"grip keys weigh the hands that reach the carried bones and need carry keys"
		)
		def.Bones = keyframes.ApplyGrip
	end

	return def
end

function keyframes.Register(name, def, poses)
	animations.Register(name, keyframes.Compile(def, poses))
	return def
end

return keyframes
