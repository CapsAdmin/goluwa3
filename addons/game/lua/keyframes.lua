local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local animations = import("lua/animations.lua")
local keyframes = {}
keyframes.Tracks = {
	{Name = "aim", Key = "AimKeys", Rest = {0, 0}},
	{Name = "hand", Key = "HandKeys", Rest = {0, 0, 0, 0, 0, 0}},
	{Name = "torso", Key = "TorsoKeys", Rest = {0}},
	{Name = "head", Key = "HeadKeys", Rest = {1, 0, 0, 0}},
	{Name = "pelvis", Key = "PelvisKeys", Rest = {0, 0, 0, 0, 0, 0}},
	{Name = "body", Key = "BodyKeys", Rest = {0, 0, 0, 0, 0, 0}},
}
keyframes.Poses = {rest = {}}

for _, track in ipairs(keyframes.Tracks) do
	keyframes.Poses.rest[track.Name] = track.Rest
end

keyframes.BodyPivot = 0.95
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

local function add_key(rows, t, values, ease)
	local row = {t, ease = ease}

	for i, v in ipairs(values) do
		row[i + 1] = v
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
			(row[3] or 0) > AIRBORNE_LIFT or
			math.abs(row[6] or 0) > AIRBORNE_TILT or
			math.abs(row[7] or 0) > AIRBORNE_TILT
		then
			return true
		end
	end

	return false
end

do
	local sample = {0, 0, 0, 0, 0, 0}
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

	function keyframes.ApplyBody(inst, pose, position, rotation)
		local def = inst.def

		if def.Face then face(inst, pose, position, rotation) end

		if not def.BodyKeys then return end

		animations.SampleKeys(def.BodyKeys, inst.phase, sample, 6)
		local w = inst.weight
		faced:Set(rotation.x, rotation.y, rotation.z, rotation.w)
		turn:Set(rotation.x, rotation.y, rotation.z, rotation.w)
		turn:RotateYaw(sample[4] * w):RotatePitch(sample[5] * w):RotateRoll(sample[6] * w)
		pivot:Set(0, keyframes.BodyPivot, 0)
		offset:Set(sample[1] * w, sample[2] * w, sample[3] * w)
		local moved = position + faced:VecMul(offset) + faced:VecMul(pivot) - turn:VecMul(pivot)
		position:Set(moved.x, moved.y, moved.z)
		rotation:Set(turn.x, turn.y, turn.z, turn.w)
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
				if not rows[1] and frame.t > 0 then add_key(rows, 0, track.Rest) end

				add_key(rows, frame.t, values, frame.ease)
			end
		end

		if rows[1] and not is_rest(rows, track.Rest) then
			if rows[#rows][1] < 1 then add_key(rows, 1, track.Rest) end

			def[track.Key] = rows
		end
	end

	if def.BodyKeys and def.Legs == nil and is_airborne(def.BodyKeys) then
		def.Legs = false
	end

	if def.BodyKeys or def.Face then def.Body = keyframes.ApplyBody end

	return def
end

function keyframes.Register(name, def, poses)
	animations.Register(name, keyframes.Compile(def, poses))
	return def
end

return keyframes
