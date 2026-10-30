local Vec3 = import("goluwa/structs/vec3.lua")
local keyframes = import("lua/keyframes.lua")
local animations = import("lua/animations.lua")
local actors = import("lua/actors.lua")
local movesets = {}
movesets.Registered = {}
movesets.ByAction = {}
local TARGET_CONE = 0.35
local TARGET_CLOSE = 1.2
local VIRTUAL_APPROACH = 1.5
local MIN_GAP = 0.45
local SWING_LEAD = 0.14
local SWING_TRAIL = 0.06

local function compile_motion(motion)
	local rows = {{0, 0, 0, 0}}

	for _, key in ipairs(motion or {}) do
		rows[#rows + 1] = {
			key[1],
			math.rad(key[2] or 0),
			key[3] or
			0,
			key[3] and
			1 or
			0,
			ease = key.ease,
		}
	end

	local last = rows[#rows]

	if last[1] < 1 then rows[#rows + 1] = {1, last[2], last[3], last[4]} end

	return rows
end

local function first_distance(rows)
	for _, row in ipairs(rows) do
		if row[4] > 0 then return row[3] end
	end
end

function movesets.Register(name, def)
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
		move.MotionKeys = compile_motion(move.Motion)
		move.VirtualDistance = (
				first_distance(move.MotionKeys) or
				1.2
			) + math.min(move.Approach, VIRTUAL_APPROACH)
		local last_hit = 0

		for _, hit in ipairs(move.Hits) do
			hit.Damage = hit.Damage or 1
			hit.Swing = hit.Swing or {hit.At - SWING_LEAD, hit.At + SWING_TRAIL}
			last_hit = math.max(last_hit, hit.At)
		end

		move.Cancel = math.max(move.Cancel or 0.8, last_hit)
		keyframes.Register(move.Action, move, def.Poses)
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

function movesets.Get(name)
	return assert(movesets.Registered[name], "unknown moveset " .. name)
end

function movesets.GetMove(action)
	return movesets.ByAction[action]
end

function movesets.IsSwinging(move, phase)
	for _, hit in ipairs(move.Hits) do
		if phase >= hit.Swing[1] and phase <= hit.Swing[2] then return hit end
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
	return movesets.Anchor(frame, target and actors.GetCenter(target):Copy() or center + forward * move.VirtualDistance)
end

function movesets.GetFocus(frame)
	local target = frame.target

	if target and target:IsValid() and actors.IsAlive(target) then
		return actors.GetCenter(target)
	end

	return frame.point
end

return movesets
