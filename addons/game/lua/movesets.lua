local Vec3 = import("goluwa/structs/vec3.lua")
local keyframes = import("lua/keyframes.lua")
local animations = import("lua/animations.lua")
local actors = import("lua/actors.lua")
local movesets = {}
movesets.Registered = {}
movesets.ByAction = {}
movesets.Source = {}
movesets.Paths = {}
local TARGET_CONE = 0.35
local TARGET_CLOSE = 1.2
local VIRTUAL_APPROACH = 1.5
local MIN_GAP = 0.45
local SWING_LEAD = 0.14
local SWING_TRAIL = 0.06

local function first_distance(rows)
	for _, row in ipairs(rows) do
		if row[4] > 0 then return row[3] end
	end
end

local SET_KEYS = {
	ComboWindow = true,
	Combo = true,
	Heavy = true,
	Air = true,
	Dash = true,
	Poses = true,
	Moves = true,
}
local MOVE_KEYS = {
	Duration = true,
	Stamina = true,
	Reach = true,
	Approach = true,
	Retreat = true,
	Cancel = true,
	Branch = true,
	Next = true,
	Face = true,
	PoseWeapon = true,
	Group = true,
	Legs = true,
	CarryBones = true,
	Keys = true,
	Events = true,
}
local EVENT_TYPES = {
	hit = {
		keys = {Cut = 3, Damage = "number", Range = "number", Swing = 2, Knock = 3},
		required = {"Cut"},
	},
	latch = {keys = {Range = "number"}, required = {"Range"}},
	release = {
		keys = {Damage = "number", Inherit = "number", Throw = 3},
		required = {"Damage", "Inherit", "Throw"},
	},
}
movesets.EventTypes = EVENT_TYPES
local KEY_FIELDS = {ease = true, hold = true}
local TRACKS = {}

for _, track in ipairs(keyframes.Tracks) do
	TRACKS[track.Name] = track
end

local function check_plain(value, path)
	local kind = type(value)

	if kind == "table" then
		assert(getmetatable(value) == nil, path .. " is not plain data")

		for k, v in pairs(value) do
			check_plain(v, path .. "." .. tostring(k))
		end
	else
		assert(
			kind == "number" or kind == "string" or kind == "boolean",
			path .. " is not plain data (" .. kind .. ")"
		)
	end
end

local function check_numbers(value, count, path)
	assert(
		type(value) == "table" and #value == count,
		path .. " must be a list of " .. count .. " numbers"
	)

	for i = 1, count do
		assert(type(value[i]) == "number", path .. "[" .. i .. "] must be a number")
	end
end

local function validate_pose(pose, path)
	for key, value in pairs(pose) do
		if key ~= "base" then
			local track = assert(TRACKS[key], path .. " has an unknown track " .. tostring(key))
			assert(
				type(value) == "number" or type(value) == "table" and #value <= #track.Rest,
				path .. "." .. key .. " takes at most " .. #track.Rest .. " numbers"
			)
		end
	end
end

local function validate_move(move, poses, path)
	for key in pairs(move) do
		assert(MOVE_KEYS[key], path .. " has an unknown field " .. tostring(key))
	end

	assert(type(move.Duration) == "number", path .. ".Duration must be a number")
	assert(move.Keys, path .. " needs Keys")
	local previous = {}

	for i, frame in ipairs(move.Keys) do
		local at = path .. ".Keys[" .. i .. "]"
		assert(
			type(frame[1]) == "number" and frame[1] >= 0 and frame[1] <= 1,
			at .. " needs a time between 0 and 1"
		)
		assert(
			frame[2] == nil or poses[frame[2]],
			at .. " names an unknown pose " .. tostring(frame[2])
		)

		for key, value in pairs(frame) do
			if type(key) == "string" then
				local track = TRACKS[key]
				assert(track or KEY_FIELDS[key], at .. " has an unknown field " .. key)

				if track then
					assert(
						type(value) == "number" or type(value) == "table" and #value <= #track.Rest,
						at .. "." .. key .. " takes at most " .. #track.Rest .. " numbers"
					)
					assert(
						not previous[key] or frame[1] > previous[key],
						at .. "." .. key .. " is not later than the previous " .. key .. " key"
					)
					previous[key] = frame[1] + (frame.hold or 0)
				end
			end
		end
	end

	local last = 0

	for i, event in ipairs(move.Events or {}) do
		local at = path .. ".Events[" .. i .. "]"
		local spec = assert(EVENT_TYPES[event.Type], at .. " has an unknown Type " .. tostring(event.Type))
		assert(
			type(event.At) == "number" and event.At >= last and event.At <= 1,
			at .. ".At must be in order between 0 and 1"
		)
		last = event.At

		for key, value in pairs(event) do
			if key ~= "At" and key ~= "Type" then
				local kind = assert(spec.keys[key], at .. " (" .. event.Type .. ") has an unknown field " .. key)

				if kind == "number" then
					assert(type(value) == "number", at .. "." .. key .. " must be a number")
				else
					check_numbers(value, kind, at .. "." .. key)
				end
			end
		end

		for _, key in ipairs(spec.required) do
			assert(event[key] ~= nil, at .. " (" .. event.Type .. ") needs " .. key)
		end
	end
end

function movesets.Validate(name, def)
	check_plain(def, name)

	for key in pairs(def) do
		assert(SET_KEYS[key], name .. " has an unknown field " .. tostring(key))
	end

	local poses = setmetatable(def.Poses or {}, {__index = keyframes.Poses})

	for pose_name, pose in pairs(def.Poses or {}) do
		validate_pose(pose, name .. ".Poses." .. pose_name)
	end

	for move_name, move in pairs(def.Moves) do
		validate_move(move, poses, name .. ".Moves." .. move_name)
	end
end

function movesets.Register(name, def, path)
	movesets.Validate(name, def)
	movesets.Paths[name] = path or movesets.Paths[name]
	movesets.Source[name] = table.copy(def)
	local poses = def.Poses
	def.Poses = nil
	def.Name = name
	def.ComboWindow = def.ComboWindow or 0.5

	for move_name, move in pairs(def.Moves) do
		move.Name = move_name
		move.Action = name .. "_" .. move_name
		move.Group = move.Group or "melee"
		move.PoseWeapon = move.PoseWeapon ~= false
		move.Face = move.Face ~= false
		move.Stamina = move.Stamina or 10
		move.Reach = move.Reach or 4
		move.Approach = move.Approach or 0.5
		move.Retreat = move.Retreat or 0.3
		move.Events = move.Events or {}
		local last_event = 0

		for _, event in ipairs(move.Events) do
			if event.Type == "hit" then
				event.Damage = event.Damage or 1
				event.Swing = event.Swing or {event.At - SWING_LEAD, event.At + SWING_TRAIL}
				event.Cut = Vec3(unpack(event.Cut))

				if event.Knock then event.Knock = Vec3(unpack(event.Knock)) end
			elseif event.Type == "release" then
				event.Throw = Vec3(unpack(event.Throw))
			end

			last_event = math.max(last_event, event.At)
		end

		move.Cancel = math.max(move.Cancel or 0.8, last_event)
		keyframes.Register(move.Action, move, poses)
		move.MotionKeys = move.MotionKeys or {{0, 0, 0, 0}, {1, 0, 0, 0}}
		move.VirtualDistance = (
				first_distance(move.MotionKeys) or
				1.2
			) + math.min(move.Approach, VIRTUAL_APPROACH)
		movesets.ByAction[move.Action] = move
	end

	for i, move_name in ipairs(def.Combo) do
		def.Combo[i] = assert(def.Moves[move_name], name .. " has no move " .. move_name)
	end

	for _, key in ipairs{"Heavy", "Air", "Dash"} do
		if def[key] then
			def[key] = assert(def.Moves[def[key]], name .. " has no move " .. def[key])
		end
	end

	for _, move in pairs(def.Moves) do
		if move.Next then
			move.Next = assert(def.Moves[move.Next], name .. " has no move " .. move.Next)
		end

		if move.Branch then
			move.Branch = assert(def.Moves[move.Branch], name .. " has no move " .. move.Branch)
		end
	end

	movesets.Registered[name] = def
	return def
end

function movesets.Update(name, def)
	return movesets.Register(name, table.copy(def))
end

do
	local vfs = import("goluwa/vfs.lua")
	local KEY_PRIORITY = {
		"Combo",
		"Heavy",
		"Air",
		"Dash",
		"ComboWindow",
		"Poses",
		"Moves",
		"Duration",
		"Stamina",
		"Reach",
		"Approach",
		"Retreat",
		"Cancel",
		"Branch",
		"Next",
		"Face",
		"PoseWeapon",
		"Group",
		"Legs",
		"CarryBones",
		"Keys",
		"Events",
		"At",
		"Type",
	}

	function movesets.Reload(name)
		local path = assert(
			movesets.Paths[name] and vfs.GetAbsolutePath(movesets.Paths[name]),
			"there is no file for moveset " .. name
		)
		return movesets.Update(name, assert(loadfile(path))())
	end

	function movesets.Save(name)
		local path = movesets.Paths[name] and vfs.GetAbsolutePath(movesets.Paths[name])
		assert(path, "there is no file for moveset " .. name)
		local file = assert(io.open(path, "wb"))
		file:write(table.to_source(movesets.Source[name], KEY_PRIORITY))
		file:close()
		return path
	end
end

function movesets.GetEvent(move, event_type)
	for _, event in ipairs(move.Events) do
		if event.Type == event_type then return event end
	end
end

function movesets.Get(name)
	return assert(movesets.Registered[name], "unknown moveset " .. name)
end

function movesets.GetMove(action)
	return movesets.ByAction[action]
end

function movesets.IsSwinging(move, phase)
	for _, event in ipairs(move.Events) do
		if event.Swing and phase >= event.Swing[1] and phase <= event.Swing[2] then
			return event
		end
	end
end

function movesets.FindTarget(holder, center, forward, reach)
	local best, best_score

	for _, victim in ipairs(actors.Find(center, reach, holder)) do
		local to_victim = actors.GetCenter(victim) - center
		to_victim.y = 0
		local distance = to_victim:GetLength()

		if distance > 1e-3 then
			local dot = to_victim:Dot(forward) / distance

			if dot > TARGET_CONE or distance < TARGET_CLOSE then
				local score = distance * (2 - dot)

				if not best_score or score < best_score then
					best, best_score = victim, score
				end
			end
		end
	end

	return best
end

do
	local sample = {0, 0, 0}

	function movesets.SampleMotion(move, f, frame, point, out)
		animations.SampleKeys(move.MotionKeys, f, sample, 3)
		local start = frame.distance
		local distance = math.clamp(
			math.lerp(sample[3], start, sample[2]),
			start - move.Approach,
			start + move.Retreat
		)
		distance = math.max(distance, MIN_GAP)
		local c, s = math.cos(sample[1]), math.sin(sample[1])
		local bearing, right = frame.bearing, frame.right
		return out:Set(
			point.x + (bearing.x * c + right.x * s) * distance,
			point.y,
			point.z + (bearing.z * c + right.z * s) * distance
		)
	end
end

function movesets.Anchor(frame, point)
	local bearing = frame.start - point
	bearing.y = 0
	local distance = bearing:GetLength()
	bearing = distance > 1e-3 and bearing / distance or frame.forward * -1
	frame.point = point
	frame.bearing = bearing
	frame.right = Vec3(bearing.z, 0, -bearing.x)
	frame.distance = distance
	return frame
end

function movesets.NewFrame(holder, move, frame)
	local center = actors.GetCenter(holder)
	local forward = actors.GetForward(holder)
	local target = movesets.FindTarget(holder, center, forward, move.Reach)
	frame.target = target
	frame.start = center:Copy()
	frame.forward = forward
	return movesets.Anchor(
		frame,
		target and
			actors.GetCenter(target):Copy() or
			center + forward * move.VirtualDistance
	)
end

function movesets.GetFocus(frame)
	local target = frame.target

	if target and target:IsValid() and actors.IsAlive(target) then
		return actors.GetCenter(target)
	end

	return frame.point
end

return movesets
