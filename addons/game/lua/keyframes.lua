local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local animations = import("lua/animations.lua")
local aim_pose = import("lua/aim_pose.lua")
local keyframes = {}
keyframes.Tracks = {
	{
		Name = "aim",
		Overlay = true,
		Key = "AimKeys",
		Rest = {0, 0},
		Labels = {"yaw", "pitch"},
		Radians = {1, 2},
	},
	{
		Name = "hand",
		Overlay = true,
		Key = "HandKeys",
		Rest = {0, 0, 0, 0, 0, 0},
		Labels = {"x", "y", "z", "pitch", "yaw", "roll"},
		Radians = {4, 5, 6},
	},
	{
		Name = "torso",
		Overlay = true,
		Key = "TorsoKeys",
		Rest = {0},
		Labels = {"pitch"},
		Radians = {1},
	},
	{
		Name = "head",
		Overlay = true,
		Key = "HeadKeys",
		Rest = {1, 0, 0, 0},
		Labels = {"follow", "nod", "turn", "tilt"},
		Radians = {2, 3, 4},
	},
	{
		Name = "pelvis",
		Overlay = true,
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
		Rest = {0, 0, 0, 0},
		Labels = {"orbit", "distance", "blend", "height"},
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
	{
		Name = "impale",
		Key = "ImpaleKeys",
		Rest = {0, 1},
		Labels = {"weight", "along"},
	},
}
keyframes.Poses = {rest = {}}

for _, track in ipairs(keyframes.Tracks) do
	keyframes.Poses.rest[track.Name] = track.Rest
end

keyframes.FaceIn = 0.12
keyframes.FaceOut = 0.2
local AIRBORNE_LIFT = 0.15
local AIRBORNE_TILT = 0.3

do
	local function get_time(def, segment, phase, clip)
		local from = segment.In or 0
		local into = (phase - segment[1]) * def.Duration

		if segment.Speed then
			local span = (segment.Out or clip.Duration) - from
			return from + (span > 0 and into * segment.Speed % span or 0)
		end

		local length = (segment[2] - segment[1]) * def.Duration
		return from + ((segment.Out or clip.Duration) - from) * math.min(into / length, 1)
	end

	function keyframes.SampleClip(def, phase, clips)
		local segments = def.Clips
		local incoming, incoming_clip

		for i = #segments, 1, -1 do
			local segment = segments[i]

			if phase >= segment[1] and (phase < segment[2] or segment[2] >= 1) then
				local clip = clips[segment[3]]

				if clip then
					if not incoming then
						incoming, incoming_clip = segment, clip
					else
						local t = math.clamp((phase - incoming[1]) / (segment[2] - incoming[1]), 0, 1)
						return segment,
						get_time(def, segment, phase, clip),
						clip,
						incoming,
						get_time(def, incoming, phase, incoming_clip),
						t * t * (3 - 2 * t)
					end
				end
			end
		end

		if incoming then
			return incoming, get_time(def, incoming, phase, incoming_clip), incoming_clip
		end
	end
end

function keyframes.ClipSequence(inst, suffix, clips)
	local segment = keyframes.SampleClip(inst.def, inst.phase, clips)
	return segment and segment[3]
end

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

local function expand(frames)
	local expanded = {}

	for _, frame in ipairs(frames) do
		local entry = {t = frame[1], ease = frame.ease, values = {}}

		for _, track in ipairs(keyframes.Tracks) do
			local value = frame[track.Name]

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
		local face_out = inst.def.FaceOut or keyframes.FaceOut
		local blend = math.min(f / keyframes.FaceIn, face_out > 0 and (1 - f) / face_out or 1, 1)
		blend = blend * blend * (3 - 2 * blend) * inst.weight
		local forward = rotation:GetForward()
		local dx, dz = point.x - position.x, point.z - position.z

		if dx * dx + dz * dz < 1e-4 then return end

		local delta = math.normalizeangle(math.atan2(-dx, -dz) - math.atan2(-forward.x, -forward.z))
		turn:Identity():RotateYaw(delta * blend)
		faced:SetMul(turn, rotation)
		rotation:Set(faced.x, faced.y, faced.z, faced.w)
	end

	local function fade_angle(angle, weight)
		local turns = math.floor(angle / math.tau + 0.5) * math.tau
		return turns + (angle - turns) * weight
	end

	local function apply_body_keys(keys, phase, weight, position, rotation)
		animations.SampleKeys(keys, phase, sample, 9)
		faced:Set(rotation.x, rotation.y, rotation.z, rotation.w)
		turn:Set(rotation.x, rotation.y, rotation.z, rotation.w)
		turn:RotateYaw(fade_angle(sample[4], weight)):RotatePitch(fade_angle(sample[5], weight)):RotateRoll(fade_angle(sample[6], weight))
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
	local target = Vec3()

	function keyframes.EvaluateCarry(def, phase, victim_bones, offset, rotation)
		animations.SampleKeys(def.CarryKeys, phase, sample, 9)
		rotation:SetAngles(angles:Set(sample[7], sample[8], sample[9]))
		local right, left = victim_bones[def.CarryBones[1]], victim_bones[def.CarryBones[2]]
		rotated:CopyFrom(
			rotation:VecMul(
				middle:Set((right.m30 + left.m30) / 2, (right.m31 + left.m31) / 2, (right.m32 + left.m32) / 2)
			)
		)
		target:Set((sample[1] + sample[4]) / 2, (sample[2] + sample[5]) / 2, (sample[3] + sample[6]) / 2)
		return offset:Set(target.x - rotated.x, target.y - rotated.y, target.z - rotated.z),
		rotation,
		target
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
	local impale = {0, 1}

	function keyframes.EvaluateImpale(def, phase)
		if not def.ImpaleKeys then return 0, 1 end

		animations.SampleKeys(def.ImpaleKeys, phase, impale, 2)
		return impale[1], impale[2]
	end

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
	local HAND_NAMES = {"right", "left"}
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
		local hands = def.GripHands

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
			if hands == nil or hands == HAND_NAMES[i] then
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
end

do
	local DEFAULT_FADE = 0.1
	local EPS = 1e-7
	local STEP = 1e-5
	local SAMPLES_PER_SECOND = 24
	local MAX_SAMPLES = 48
	local EASES = animations.Eases
	keyframes.DefaultFade = DEFAULT_FADE
	keyframes.OverlayTracks = {}

	for _, track in ipairs(keyframes.Tracks) do
		if track.Overlay then table.insert(keyframes.OverlayTracks, track) end
	end

	function keyframes.GetOverlayTimes(overlays, duration)
		local arrive, depart, covered_in, covered_out = {}, {}, {}, {}

		for i, entry in ipairs(overlays) do
			local previous, following = overlays[i - 1], overlays[i + 1]
			local from, to = entry[1], entry[2]
			covered_in[i] = previous ~= nil and previous[2] > from
			covered_out[i] = following ~= nil and following[1] < to
			local a = covered_in[i] and
				previous[2] or
				math.min(from + (entry.FadeIn or DEFAULT_FADE) / duration, to)
			local d = covered_out[i] and
				following[1] or
				math.max(to - (entry.FadeOut or DEFAULT_FADE) / duration, from)

			if a > d then
				a = (a + d) / 2
				d = a
			end

			arrive[i], depart[i] = a, d
		end

		return arrive, depart, covered_in, covered_out
	end

	local function fill(track, value)
		local values = to_values(track, value)
		local filled = {}

		for i = 1, #track.Rest do
			filled[i] = values[i] == nil and track.Rest[i] or values[i]
		end

		return filled
	end

	local function resolve_clip(pose, poses)
		local clip = {Duration = pose.Duration or 0, values = {}, rows = {}}

		for _, track in ipairs(keyframes.OverlayTracks) do
			if pose[track.Name] ~= nil then
				clip.values[track.Name] = fill(track, pose[track.Name])
			end
		end

		for _, key in ipairs(pose.Keys or {}) do
			local base = type(key[2]) == "string" and resolve_pose(key[2], poses) or nil

			for _, track in ipairs(keyframes.OverlayTracks) do
				local value = key[track.Name]

				if value == nil and base then value = base[track.Name] end

				if value ~= nil then
					local rows = clip.rows[track.Name] or {}
					clip.rows[track.Name] = rows
					local row = {key[1], ease = key.ease}

					for i, v in ipairs(fill(track, value)) do
						row[i + 1] = v
					end

					rows[#rows + 1] = row
				end
			end
		end

		return clip
	end

	local function get_blocks(def, poses, gestures)
		local blocks = {}
		local arrive, depart, covered_in, covered_out = keyframes.GetOverlayTimes(def.Overlays, (def.Duration or 1))

		for i, entry in ipairs(def.Overlays) do
			local clip = resolve_clip(gestures and gestures[entry[3]] or resolve_pose(entry[3], poses), poses)
			local block = {
				entry = entry,
				clip = clip,
				from = entry[1],
				to = entry[2],
				arrive = arrive[i],
				depart = depart[i],
				covered_in = covered_in[i],
				covered_out = covered_out[i],
				values = {},
				rows = {},
			}

			for _, track in ipairs(keyframes.OverlayTracks) do
				local name = track.Name

				if entry[name] ~= nil then
					block.values[name] = fill(track, entry[name])
				elseif clip.rows[name] then
					block.rows[name] = clip.rows[name]
				else
					block.values[name] = clip.values[name] or fill(track, track.Rest)
				end
			end

			blocks[i] = block
		end

		return blocks
	end

	local function get_local_time(def, block, f)
		local entry, duration = block.entry, block.clip.Duration
		local from = entry.In or 0
		local out = entry.Out or duration
		local into = (f - block.from) * (def.Duration or 1)

		if entry.Speed then
			local span = out - from
			return from + (span > 0 and into * entry.Speed % span or 0)
		end

		local length = (block.to - block.from) * (def.Duration or 1)
		return from + (out - from) * math.min(into / length, 1)
	end

	local function sample_block(def, block, track, f, out)
		local rows = block.rows[track.Name]

		if rows then
			return animations.SampleKeys(rows, get_local_time(def, block, f), out, #track.Rest)
		end

		local values = block.values[track.Name]

		for i = 1, #track.Rest do
			out[i] = values[i]
		end

		return out
	end

	local function wrap_turns(track, value, out)
		for i = 1, #track.Rest do
			out[i] = track.Rest[i]
		end

		for _, i in ipairs(track.Radians or {}) do
			out[i] = math.floor(value[i] / math.tau + 0.5) * math.tau
		end

		return out
	end

	local scratch = {{}, {}, {}}

	local function sample_enveloped(def, block, track, f, out)
		local value = sample_block(def, block, track, f, out)

		if not block.covered_in and f < block.arrive then
			local r = EASES[block.entry.Ease or
			"smooth"]((f - block.from) / (block.arrive - block.from))

			for i = 1, #track.Rest do
				value[i] = track.Rest[i] + (value[i] - track.Rest[i]) * r
			end
		end

		if not block.covered_out and f > block.depart then
			local r = EASES.smooth((block.to - f) / (block.to - block.depart))
			local target = wrap_turns(track, value, scratch[3])

			for i = 1, #track.Rest do
				value[i] = target[i] + (value[i] - target[i]) * r
			end
		end

		return value
	end

	local function find_active(blocks, f)
		local later, earlier

		for i = #blocks, 1, -1 do
			local block = blocks[i]

			if f >= block.from and (f < block.to or block.to >= 1) then
				if not later then
					later = block
				else
					earlier = block

					break
				end
			end
		end

		return later, earlier
	end

	local function sample_lane(def, blocks, track, f, out)
		local later, earlier = find_active(blocks, f)

		if not later then
			for i = 1, #track.Rest do
				out[i] = track.Rest[i]
			end

			return out
		end

		if not earlier then return sample_enveloped(def, later, track, f, out) end

		local a = sample_enveloped(def, earlier, track, f, scratch[1])
		local b = sample_enveloped(def, later, track, f, scratch[2])
		local x = EASES[later.entry.Ease or
		"smooth"](math.clamp((f - later.from) / (earlier.to - later.from), 0, 1))

		for i = 1, #track.Rest do
			out[i] = a[i] + (b[i] - a[i]) * x
		end

		return out
	end

	local function get_span(def, block, track, x0, x1)
		local rows = block.rows[track.Name]

		if not rows then return "constant" end

		if block.entry.Speed then return end

		local t0, t1 = get_local_time(def, block, x0), get_local_time(def, block, x1)

		if t1 <= rows[1][1] + 1e-9 or t0 >= rows[#rows][1] - 1e-9 then
			return "constant"
		end

		for k = 2, #rows do
			if math.abs(rows[k - 1][1] - t0) < 1e-6 and math.abs(rows[k][1] - t1) < 1e-6 then
				return "segment", rows[k].ease
			end
		end
	end

	local function build_overlay_rows(def, blocks, track)
		local points = {0, 1}

		for _, block in ipairs(blocks) do
			table.insert(points, block.from)
			table.insert(points, block.to)
			table.insert(points, block.arrive)
			table.insert(points, block.depart)
			local rows = block.rows[track.Name]

			if rows and not block.entry.Speed then
				local from = block.entry.In or 0
				local span = (block.entry.Out or block.clip.Duration) - from

				for _, row in ipairs(rows) do
					local phase = block.from + (row[1] - from) / span * (block.to - block.from)

					if phase > block.from and phase < block.to then table.insert(points, phase) end
				end
			end
		end

		table.sort(points)
		local rows = {}
		local count = #track.Rest
		local from_value, to_value, middle = {}, {}, {}

		local function add(x, values, ease)
			local last = rows[#rows]

			if last and x <= last[1] + 1e-9 then
				local same = true

				for i = 1, count do
					same = same and math.abs(last[i + 1] - values[i]) < 1e-6
				end

				if same then return end

				x = last[1] + STEP
			end

			local row = {x, ease = ease}

			for i = 1, count do
				row[i + 1] = values[i]
			end

			rows[#rows + 1] = row
		end

		for i = 1, #points - 1 do
			local x0, x1 = points[i], points[i + 1]

			if x1 - x0 > 1e-9 then
				local mid = (x0 + x1) / 2
				local later, earlier = find_active(blocks, mid)
				local ease
				local exact = true

				if later and earlier then
					ease = later.entry.Ease or "smooth"
					exact = get_span(def, later, track, x0, x1) == "constant" and
						get_span(def, earlier, track, x0, x1) == "constant"
				elseif later then
					local span, span_ease = get_span(def, later, track, x0, x1)

					if not later.covered_in and mid < later.arrive then
						ease = later.entry.Ease or "smooth"
						exact = span == "constant"
					elseif not later.covered_out and mid > later.depart then
						ease = "smooth"
						exact = span == "constant"
					else
						exact = span ~= nil
						ease = span_ease
					end
				end

				add(x0, sample_lane(def, blocks, track, x0 + EPS, from_value))

				if exact then
					add(x1, sample_lane(def, blocks, track, x1 - EPS, to_value), ease)
				else
					local samples = math.clamp(
						math.ceil((x1 - x0) * (def.Duration or 1) * SAMPLES_PER_SECOND),
						2,
						MAX_SAMPLES
					)

					for k = 1, samples - 1 do
						local x = x0 + (x1 - x0) * k / samples
						add(x, sample_lane(def, blocks, track, x, middle), "linear")
					end

					add(x1, sample_lane(def, blocks, track, x1 - EPS, to_value), "linear")
				end
			end
		end

		return rows
	end

	function keyframes.CompileOverlays(def, poses, gestures)
		local blocks = get_blocks(def, poses, gestures)
		local rows = {}

		for _, track in ipairs(keyframes.OverlayTracks) do
			rows[track.Name] = build_overlay_rows(def, blocks, track)
		end

		return rows
	end
end

function keyframes.Compile(def, poses, gestures)
	def.Kind = def.Kind or "action"
	local frames = expand(def.Keys or {})
	local overlay_rows = def.Overlays and keyframes.CompileOverlays(def, poses, gestures)

	for _, track in ipairs(keyframes.Tracks) do
		local rows = {}

		if track.Overlay then
			rows = overlay_rows and overlay_rows[track.Name] or rows
		else
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
		end

		if rows[1] and not is_rest(rows, track.Rest) then
			if not track.Overlay and rows[#rows][1] < 1 and not track.Extend then
				local last = rows[#rows]
				local values = {unpack(track.Rest)}

				for _, i in ipairs(track.Radians or {}) do
					values[i] = math.floor(last[i + 1] / math.tau + 0.5) * math.tau
				end

				add_key(rows, 1, values, nil, track)
			end

			def[track.Key] = rows
		end
	end

	if def.BodyKeys and def.Legs == nil and is_airborne(def.BodyKeys) then
		def.Legs = false
	end

	if def.BodyKeys or def.Face then def.Body = keyframes.ApplyBody end

	if def.Clips then
		def.Sequence = keyframes.ClipSequence
		def.Loop = false
	end

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

	if def.ImpaleKeys then
		assert(
			def.CarryKeys,
			"impale keys pin the carried bones to the held weapon and need carry keys"
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

function keyframes.Register(name, def, poses, gestures)
	animations.Register(name, keyframes.Compile(def, poses, gestures))
	return def
end

return keyframes
