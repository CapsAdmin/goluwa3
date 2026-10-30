local keyframes = import("lua/keyframes.lua")
local animations = import("lua/animations.lua")
local movesets = import("lua/movesets.lua")
local move_edit = {}
move_edit.EventDefaults = {
	hit = {Cut = {0, 0, 1}},
	latch = {Range = 2.5},
	release = {Damage = 1, Inherit = 1, Throw = {0, 1, 2}},
}
move_edit.EventTypes = {"hit", "latch", "release"}
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
		fields[#fields + 1] = {Name = key, Count = kind == "number" and 1 or kind}
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

function move_edit.Rows(move)
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
					Track = track.Name,
				}
			end
		end

		if keys[1] then
			by_track[track.Name] = #rows + 1
			rows[#rows + 1] = {Name = track.Name, Color = "text_disabled", Keys = keys}
		end
	end

	for _, event_type in ipairs(move_edit.EventTypes) do
		local keys = {}

		for _, event in ipairs(move.Events or {}) do
			if event.Type == event_type then
				keys[#keys + 1] = {Time = event.At, Label = event_type, Event = event}
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
