local clip_edit = {}
clip_edit.EventTemplate = {0, Flash = true, Lumen = 10, Time = 0.3}
clip_edit.MIN_STEP = 0.001

local function get_track_names(data)
	local names = {}

	for name, spec in pairs(data.Tracks or {}) do
		names[#names + 1] = name
	end

	table.sort(names)
	return names
end

function clip_edit.Rows(data)
	local rows = {}

	for _, name in ipairs(get_track_names(data)) do
		local spec = data.Tracks[name]
		local keys = {}

		if type(spec) == "table" then
			for index, key in ipairs(spec) do
				keys[index] = {Time = key[1], Track = name, Index = index}
			end
		end

		rows[#rows + 1] = {
			Name = type(spec) == "table" and name or name .. " (expr)",
			Color = "text_disabled",
			Track = name,
			Keys = keys,
		}
	end

	local keys = {}

	for index, event in ipairs(data.Events or {}) do
		local label = event.Call or event.Burst or event.Debris or event.Flash and "flash"
		keys[index] = {
			Time = event[1],
			Event = event,
			Index = index,
			Label = label and tostring(label),
		}
	end

	rows[#rows + 1] = {Name = "events", Color = "primary", Keys = keys}
	return rows
end

function clip_edit.Sample(spec, time)
	local count = #spec

	if time <= spec[1][1] then return spec[1][2] end

	if time >= spec[count][1] then return spec[count][2] end

	for i = 1, count - 1 do
		local a, b = spec[i], spec[i + 1]

		if time <= b[1] then
			return a[2] + (b[2] - a[2]) * (time - a[1]) / (b[1] - a[1])
		end
	end
end

function clip_edit.MoveKey(data, row, index, time)
	if row.Track then
		local spec = data.Tracks[row.Track]
		local previous, following = spec[index - 1], spec[index + 1]
		spec[index][1] = math.clamp(
			time,
			previous and previous[1] + clip_edit.MIN_STEP or 0,
			following and following[1] - clip_edit.MIN_STEP or 1
		)
	else
		data.Events[index][1] = math.clamp(time, 0, 1)
	end
end

function clip_edit.SortEvents(data)
	table.sort(data.Events, function(a, b)
		return a[1] < b[1]
	end)
end

function clip_edit.AddKey(data, row, time)
	if row.Track then
		local spec = data.Tracks[row.Track]
		local position = #spec + 1

		for i, key in ipairs(spec) do
			if math.abs(key[1] - time) < clip_edit.MIN_STEP then return end

			if key[1] > time then
				position = i

				break
			end
		end

		table.insert(spec, position, {time, clip_edit.Sample(spec, time)})
		return {Track = row.Track, Index = position}
	end

	data.Events = data.Events or {}
	local event = table.copy(clip_edit.EventTemplate)
	event[1] = time
	data.Events[#data.Events + 1] = event
	clip_edit.SortEvents(data)

	for index, other in ipairs(data.Events) do
		if other == event then return {Event = true, Index = index} end
	end
end

function clip_edit.RemoveKey(data, selection)
	if selection.Track then
		local spec = data.Tracks[selection.Track]

		if #spec > 2 then table.remove(spec, selection.Index) end
	else
		table.remove(data.Events, selection.Index)
	end
end

return clip_edit
