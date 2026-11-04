local keyframes = import("lua/keyframes.lua")
local animations = import("lua/animations.lua")
local movesets = import("lua/movesets.lua")
local move_edit = {}
move_edit.EventDefaults = {
	hit = {Cut = {0, 0, 1}},
	strike = {Damage = 10, Range = 2},
	cast = {Element = "fire", Damage = 10},
	latch = {Range = 2.5},
	release = {Damage = 1, Inherit = 1, Throw = {0, 1, 2}},
}
move_edit.EventTypes = {"hit", "strike", "cast", "latch", "release"}
move_edit.ClipEventTypes = {strike = true, cast = true}
move_edit.WeaponEventTypes = {hit = true, latch = true, release = true}

function move_edit.GetEventTypes(move)
	local used = {}

	for _, event in ipairs(move.Events or {}) do
		used[event.Type] = true
	end

	local defaults = move.Keys and
		move.Keys[1] and
		move_edit.WeaponEventTypes or
		move_edit.ClipEventTypes
	local types = {}

	for _, event_type in ipairs(move_edit.EventTypes) do
		if used[event_type] or defaults[event_type] then
			types[#types + 1] = event_type
		end
	end

	return types
end

move_edit.Eases = {"smooth", "linear", "in", "out"}
local TRACKS = {}

for _, track in ipairs(keyframes.Tracks) do
	TRACKS[track.Name] = track
end

move_edit.TrackByName = TRACKS

local function group(label, kind, indices, radians)
	return {Label = label, Type = kind, Indices = indices, Radians = radians}
end

move_edit.TrackGroups = {
	aim = {group("yaw, pitch", "vec2", {1, 2}, true)},
	hand = {
		group("position", "vec3", {1, 2, 3}),
		group("rotation", "ang3", {4, 5, 6}, true),
	},
	head = {
		group("follow", "number", {1}),
		group("nod, turn, tilt", "ang3", {2, 3, 4}, true),
	},
	pelvis = {
		group("position", "vec3", {1, 2, 3}),
		group("rotation", "ang3", {5, 4, 6}, true),
	},
	body = {
		group("position", "vec3", {1, 2, 3}),
		group("rotation", "ang3", {5, 4, 6}, true),
		group("pivot", "vec3", {7, 8, 9}),
	},
	carry = {
		group("right", "vec3", {1, 2, 3}),
		group("left", "vec3", {4, 5, 6}),
		group("rotation", "ang3", {7, 8, 9}, true),
	},
}

function move_edit.GetGroups(track_name)
	if move_edit.TrackGroups[track_name] then
		return move_edit.TrackGroups[track_name]
	end

	local track = TRACKS[track_name]
	local radians = {}
	local groups = {}

	for _, i in ipairs(track.Radians or {}) do
		radians[i] = true
	end

	for i, label in ipairs(track.Labels) do
		groups[i] = group(label, "number", {i}, radians[i])
	end

	return groups
end

function move_edit.IsFrameEmpty(frame)
	if frame[2] ~= nil then return false end

	for name in pairs(TRACKS) do
		if frame[name] ~= nil then return false end
	end

	return true
end

function move_edit.GetTracks(frame)
	local names = {}

	for _, track in ipairs(keyframes.Tracks) do
		if frame[track.Name] ~= nil then names[#names + 1] = track.Name end
	end

	return names
end

function move_edit.GetValues(frame, track_name)
	local value = frame[track_name]
	local rest = TRACKS[track_name].Rest
	local values = {}

	for i = 1, #rest do
		if type(value) == "number" then
			values[i] = i == 1 and value or rest[i]
		else
			values[i] = value[i] == nil and rest[i] or value[i]
		end
	end

	return values
end

do
	local sample = {}

	function move_edit.Sample(def, track_name, phase)
		local track = TRACKS[track_name]
		local rows = def[track.Key]
		local count = #track.Rest

		if not rows then return table.copy(track.Rest) end

		animations.SampleKeys(rows, phase, sample, count)
		local values = {}

		for i = 1, count do
			values[i] = sample[i]
		end

		for _, i in ipairs(track.Degrees or {}) do
			values[i] = math.deg(values[i])
		end

		return values
	end
end

function move_edit.Sort(keys)
	for i = 2, #keys do
		local item = keys[i]
		local j = i - 1

		while j >= 1 and keys[j][1] > item[1] do
			keys[j + 1] = keys[j]
			j = j - 1
		end

		keys[j + 1] = item
	end
end

function move_edit.Find(keys, frame)
	for i, other in ipairs(keys) do
		if other == frame then return i end
	end
end

function move_edit.MoveFrame(move, frame, time)
	frame[1] = time
	move_edit.Sort(move.Keys)
	return move_edit.Find(move.Keys, frame)
end

function move_edit.AddTrackKey(move, track_name, time, values)
	local frame = {time, [track_name] = values}
	table.insert(move.Keys, frame)
	move_edit.Sort(move.Keys)
	return frame
end

function move_edit.AddPoseKey(move, time, pose)
	local frame = {time, pose}
	table.insert(move.Keys, frame)
	move_edit.Sort(move.Keys)
	return frame
end

function move_edit.RemoveFrame(move, frame)
	table.remove(move.Keys, move_edit.Find(move.Keys, frame))
end

function move_edit.RemoveTrack(move, frame, track_name)
	frame[track_name] = nil

	if type(frame.ease) == "table" then frame.ease[track_name] = nil end

	if move_edit.IsFrameEmpty(frame) then move_edit.RemoveFrame(move, frame) end
end

function move_edit.RemovePose(move, frame)
	frame[2] = nil

	if move_edit.IsFrameEmpty(frame) then move_edit.RemoveFrame(move, frame) end
end

function move_edit.GetKeyIdentity(key)
	return {
		Frame = key.Frame,
		Track = key.Track,
		Event = key.Event,
		Entry = key.Entry,
		List = key.List,
	}
end

function move_edit.AddEntry(move, list, time, entry)
	table.insert(entry, 1, time)
	move[list] = move[list] or {}
	table.insert(move[list], entry)
	move_edit.Sort(move[list])
	return entry
end

function move_edit.RemoveEntry(move, list, entry)
	table.remove(move[list], move_edit.Find(move[list], entry))

	if not move[list][1] then move[list] = nil end
end

function move_edit.PlaceBlock(list, entry, at, crossfade)
	local length = entry[2] - entry[1]
	local originals = {}

	for i, other in ipairs(list) do
		originals[i] = {other[1], other[2]}
	end

	at = math.clamp(at, 0, 1 - length)
	local threshold = at < entry[1] and at or at + length
	local before, after = {}, {}

	for _, other in ipairs(list) do
		if other ~= entry then
			if (other[1] + other[2]) / 2 < threshold then
				before[#before + 1] = other
			else
				after[#after + 1] = other
			end
		end
	end

	table.sort(before, function(a, b)
		return a[1] < b[1]
	end)

	table.sort(after, function(a, b)
		return a[1] < b[1]
	end)

	entry[1], entry[2] = at, at + length

	local function allowed(a, b)
		return crossfade and math.min(a[2] - a[1], b[2] - b[1]) / 2 or 0
	end

	local edge, current = at, entry

	for i = #before, 1, -1 do
		local other = before[i]
		local limit = edge + allowed(other, current)

		if other[2] > limit then
			other[1], other[2] = limit - (other[2] - other[1]), limit
		end

		edge, current = other[1], other
	end

	edge, current = entry[2], entry

	for _, other in ipairs(after) do
		local limit = edge - allowed(other, current)

		if other[1] < limit then
			other[1], other[2] = limit, limit + (other[2] - other[1])
		end

		edge, current = other[2], other
	end

	move_edit.Sort(list)
	local valid = true

	for i, other in ipairs(list) do
		valid = valid and
			other[1] >= -1e-9 and
			other[2] <= 1 + 1e-9 and
			(
				i < 3 or
				other[1] >= list[i - 2][2] - 1e-9
			)
	end

	if not valid then
		for i, other in ipairs(originals) do
			list[i][1], list[i][2] = other[1], other[2]
		end

		move_edit.Sort(list)
	end

	return valid
end

function move_edit.RemoveKey(move, key)
	if key.Entry then
		move_edit.RemoveEntry(move, key.List, key.Entry)
	elseif key.Event then
		move_edit.RemoveEvent(move, key.Event)
	elseif key.Track then
		move_edit.RemoveTrack(move, key.Frame, key.Track)
	else
		move_edit.RemovePose(move, key.Frame)
	end
end

function move_edit.RemoveKeys(move, keys)
	for _, key in ipairs(keys) do
		move_edit.RemoveKey(move, key)
	end
end

local MIN_BLOCK = 0.005

function move_edit.NewClipId(move)
	local used = {}

	for _, clip in ipairs(move.Clips or {}) do
		used[clip.Id or ""] = true
	end

	local n = 1

	while used["c" .. n] do
		n = n + 1
	end

	return "c" .. n
end

function move_edit.SplitClip(move, entry, time, clip_length)
	local from = entry.In or 0
	local out = entry.Out or clip_length
	local rate = entry.Speed or (out - from) / ((entry[2] - entry[1]) * move.Duration)
	local source = from + (time - entry[1]) * move.Duration * rate
	local right = {time, entry[2], entry[3], In = source, Out = entry.Out, Speed = entry.Speed}
	entry[2] = time

	if not entry.Speed then entry.Out = source end

	if entry.Id then
		right.Id = move_edit.NewClipId(move)

		for _, event in ipairs(move.Events or {}) do
			if event.Clip == entry.Id and event.Time >= source then event.Clip = right.Id end
		end
	end

	table.insert(move.Clips, move_edit.Find(move.Clips, entry) + 1, right)
	move_edit.Sort(move.Clips)
	return right
end

function move_edit.LinkEvent(move, event, get_length)
	local target

	for _, clip in ipairs(move.Clips or {}) do
		if event.At >= clip[1] and event.At <= clip[2] then target = clip end
	end

	local length = target and (target.Out or get_length(target[3]))

	if not length then return false end

	target.Id = target.Id or move_edit.NewClipId(move)
	target.Out = length
	local rate = target.Speed or
		(
			length - (
				target.In or
				0
			)
		) / (
			(
				target[2] - target[1]
			) * move.Duration
		)
	event.Clip = target.Id
	event.Time = (target.In or 0) + (event.At - target[1]) * move.Duration * rate
	return true
end

function move_edit.UnlinkEvent(event)
	event.Clip, event.Time = nil, nil
end

function move_edit.SetEventTime(move, event, time)
	if not event.Clip then
		event.At = time
		return
	end

	for _, clip in ipairs(move.Clips) do
		if clip.Id == event.Clip then
			local rate = clip.Speed or
				(
					(
						clip.Out or
						0
					) - (
						clip.In or
						0
					)
				) / (
					(
						clip[2] - clip[1]
					) * move.Duration
				)
			event.Time = (clip.In or 0) + (math.clamp(time, clip[1], clip[2]) - clip[1]) * move.Duration * rate
		end
	end
end

function move_edit.GetEventClip(move, event)
	for _, clip in ipairs(move.Clips or {}) do
		if event.Clip and clip.Id == event.Clip then return clip end
	end
end

function move_edit.Grab(keys)
	local grabbed = {}
	local seen = {}

	for _, key in ipairs(keys) do
		local target = key.Event or key.Entry or key.Frame

		if not seen[target] then
			seen[target] = true
			grabbed[#grabbed + 1] = {
				Target = target,
				Event = key.Event ~= nil,
				Time = key.Event and key.Event.At or target[1],
				Hold = key.Frame and key.Frame.hold or nil,
				End = (key.List == "Locks" or key.List == "Clips") and target[2] or nil,
			}
		end
	end

	return grabbed
end

function move_edit.Transform(move, grabbed, anchor, scale, offset, snap)
	for _, item in ipairs(grabbed) do
		local time = anchor + (item.Time - anchor) * scale + offset

		if snap > 0 then time = math.floor(time / snap + 0.5) * snap end

		if item.Event then
			item.Target.At = time
		else
			item.Target[1] = time

			if item.Hold then item.Target.hold = item.Hold * scale end

			if item.End then
				local finish = anchor + (item.End - anchor) * scale + offset

				if snap > 0 then finish = math.floor(finish / snap + 0.5) * snap end

				item.Target[2] = math.min(math.max(finish, time + MIN_BLOCK), 1)
			end
		end
	end

	move_edit.Sort(move.Keys)

	if move.Events then move_edit.SortEvents(move) end

	if move.Shots then move_edit.Sort(move.Shots) end

	if move.Faces then move_edit.Sort(move.Faces) end

	if move.Locks then move_edit.Sort(move.Locks) end

	if move.Clips then move_edit.Sort(move.Clips) end
end

function move_edit.Split(move, frame, track_name)
	local split = {frame[1], [track_name] = frame[track_name]}
	frame[track_name] = nil

	if type(frame.ease) == "table" then
		split.ease = frame.ease[track_name]
		frame.ease[track_name] = nil
	else
		split.ease = frame.ease
	end

	table.insert(move.Keys, move_edit.Find(move.Keys, frame) + 1, split)

	if move_edit.IsFrameEmpty(frame) then move_edit.RemoveFrame(move, frame) end

	return split
end

function move_edit.IsLinked(key)
	if key.Event or key.Entry then return false end

	local frame = key.Frame
	local count = #move_edit.GetTracks(frame) + (type(frame[2]) == "string" and 1 or 0)
	return count > 1
end

do
	local function ease_of(frame, track)
		local ease = frame.ease

		if type(ease) == "table" then return ease[track] or "smooth" end

		return ease or "smooth"
	end

	local function plan_link(keys)
		local target

		for _, key in ipairs(keys) do
			if key.Event or key.Entry then return end

			if not target or key.Frame[1] < target[1] then target = key.Frame end
		end

		if not target then return end

		local tracks = {}
		local has_pose = type(target[2]) == "string"
		local moved = {}

		for name in pairs(TRACKS) do
			tracks[name] = target[name] ~= nil
		end

		for _, key in ipairs(keys) do
			if key.Frame ~= target then
				if key.Track then
					if tracks[key.Track] then return end

					tracks[key.Track] = true
				else
					if has_pose then return end

					has_pose = true
				end

				moved[#moved + 1] = key
			end
		end

		if not moved[1] then return end

		return target, moved
	end

	function move_edit.CanLink(keys)
		return plan_link(keys) ~= nil
	end

	function move_edit.Link(move, keys)
		local target, moved = plan_link(keys)
		local eases = {}

		for name in pairs(TRACKS) do
			if target[name] ~= nil then eases[name] = ease_of(target, name) end
		end

		for _, key in ipairs(moved) do
			if key.Track then
				eases[key.Track] = ease_of(key.Frame, key.Track)
				local value = key.Frame[key.Track]
				move_edit.RemoveTrack(move, key.Frame, key.Track)
				target[key.Track] = value
			else
				local pose = key.Frame[2]
				move_edit.RemovePose(move, key.Frame)
				target[2] = pose
			end
		end

		local first, uniform = next(eases)

		if first then
			uniform = true

			for _, ease in pairs(eases) do
				uniform = uniform and ease == eases[first]
			end

			if uniform then
				move_edit.SetEase(target, eases[first])
			else
				local table_ease = {}

				for name, ease in pairs(eases) do
					table_ease[name] = ease ~= "smooth" and ease or nil
				end

				target.ease = table_ease
			end
		end

		local linked = {}

		for i, key in ipairs(keys) do
			linked[i] = {Frame = target, Track = key.Track}
		end

		return linked
	end
end

function move_edit.Unlink(move, key)
	local frame = key.Frame

	if key.Track then
		return {Frame = move_edit.Split(move, frame, key.Track), Track = key.Track}
	end

	local split = {frame[1], frame[2], ease = type(frame.ease) ~= "table" and frame.ease or nil}
	frame[2] = nil
	table.insert(move.Keys, move_edit.Find(move.Keys, frame) + 1, split)
	return {Frame = split}
end

function move_edit.SetTrackValue(frame, track_name, index, value)
	local values = move_edit.GetValues(frame, track_name)
	values[index] = value
	frame[track_name] = values
end

function move_edit.SetEase(frame, ease)
	frame.ease = ease ~= "smooth" and ease or nil
end

function move_edit.AddEvent(move, event_type, time)
	local event = {At = time, Type = event_type}

	for key, value in pairs(move_edit.EventDefaults[event_type]) do
		event[key] = table.copy(value)
	end

	move.Events = move.Events or {}
	table.insert(move.Events, event)
	move_edit.SortEvents(move)
	return event
end

function move_edit.SortEvents(move)
	local events = move.Events

	for i = 2, #events do
		local item = events[i]
		local j = i - 1

		while j >= 1 and events[j].At > item.At do
			events[j + 1] = events[j]
			j = j - 1
		end

		events[j + 1] = item
	end
end

function move_edit.RemoveEvent(move, event)
	table.remove(move.Events, move_edit.Find(move.Events, event))
end

function move_edit.GetEventFields(event_type)
	local fields = {}

	for key, kind in pairs(movesets.EventTypes[event_type].keys) do
		fields[#fields + 1] = {
			Name = key,
			Count = (kind == "number" or kind == "string") and 1 or kind,
			String = kind == "string",
		}
	end

	table.sort(fields, function(a, b)
		return a.Name < b.Name
	end)

	return fields
end

function move_edit.GetEventValues(event, field)
	local value = event[field.Name]

	if value == nil then return nil end

	return field.Count == 1 and {value} or value
end

function move_edit.SetEventValue(event, field, index, value)
	if field.Count == 1 then
		event[field.Name] = value
		return
	end

	local values = event[field.Name] or {}

	for i = 1, field.Count do
		values[i] = values[i] or 0
	end

	values[index] = value
	event[field.Name] = values
end

function move_edit.Rows(move, get_wave)
	local rows = {{Name = "pose", Color = "primary", Keys = {}}}
	local by_track = {}

	for _, frame in ipairs(move.Keys) do
		if type(frame[2]) == "string" then
			local keys = rows[1].Keys
			keys[#keys + 1] = {
				Time = frame[1],
				Until = frame.hold and frame[1] + frame.hold,
				Label = frame[2],
				Frame = frame,
				Link = frame,
			}
		end
	end

	for _, track in ipairs(keyframes.Tracks) do
		local keys = {}

		for _, frame in ipairs(move.Keys) do
			if frame[track.Name] ~= nil then
				keys[#keys + 1] = {
					Time = frame[1],
					Until = frame.hold and frame[1] + frame.hold,
					Frame = frame,
					Link = frame,
					Track = track.Name,
				}
			end
		end

		if keys[1] then
			by_track[track.Name] = #rows + 1
			rows[#rows + 1] = {Name = track.Name, Color = "text_disabled", Keys = keys}
		end
	end

	local shot_keys, face_keys, clip_keys = {}, {}, {}

	for _, clip in ipairs(move.Clips or {}) do
		local wave = get_wave and get_wave(clip[3])
		clip_keys[#clip_keys + 1] = {
			Time = clip[1],
			Until = clip[2],
			Label = clip[3],
			Entry = clip,
			List = "Clips",
			Link = clip,
			Block = true,
			Wave = wave and
				{
					Values = wave.Values,
					From = (clip.In or 0) / wave.Duration,
					To = (clip.Out or wave.Duration) / wave.Duration,
				} or
				nil,
		}
	end

	table.insert(rows, 1, {Name = "clips", Color = "primary", Keys = clip_keys})

	for _, shot in ipairs(move.Shots or {}) do
		shot_keys[#shot_keys + 1] = {Time = shot[1], Label = shot[2], Entry = shot, List = "Shots"}
	end

	for _, face in ipairs(move.Faces or {}) do
		face_keys[#face_keys + 1] = {
			Time = face[1],
			Label = (face[2] or "-") .. (face.victim and " / " .. face.victim or ""),
			Entry = face,
			List = "Faces",
		}
	end

	local lock_keys = {}

	for _, lock in ipairs(move.Locks or {}) do
		lock_keys[#lock_keys + 1] = {Time = lock[1], Until = lock[2], Entry = lock, List = "Locks"}
	end

	rows[#rows + 1] = {Name = "shots", Color = "positive", Keys = shot_keys}
	rows[#rows + 1] = {Name = "faces", Color = "neutral", Keys = face_keys}
	rows[#rows + 1] = {Name = "locks", Color = "prefab", Keys = lock_keys}

	for _, event_type in ipairs(move_edit.GetEventTypes(move)) do
		local keys = {}

		for _, event in ipairs(move.Events or {}) do
			if event.Type == event_type then
				keys[#keys + 1] = {
					Time = event.At,
					Label = event_type,
					Event = event,
					Link = move_edit.GetEventClip(move, event),
				}
			end
		end

		rows[#rows + 1] = {Name = event_type, Color = "negative", Round = true, Keys = keys}
	end

	return rows
end

function move_edit.AddableTracks(move)
	local present = {}

	for _, frame in ipairs(move.Keys) do
		for name in pairs(TRACKS) do
			if frame[name] ~= nil then present[name] = true end
		end
	end

	local names = {}

	for _, track in ipairs(keyframes.Tracks) do
		if not present[track.Name] then names[#names + 1] = track.Name end
	end

	return names
end

return move_edit
