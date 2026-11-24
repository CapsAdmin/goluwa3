local vfs = import("goluwa/vfs.lua")
local file_path = import("goluwa/filesystem/path.lua")
local fmod_events = {}
local NUMBER_FIELDS = {
	volume_db = true,
	pitch = true,
	pitch_randomization = true,
	volume_randomization = true,
	mindistance = true,
	maxdistance = true,
	maxplaybacks = true,
}

function fmod_events.ParseProject(xml)
	local sounddefs, events = {}, {}
	local stack, groups = {}, {}
	local sounddef, waveform, event, layer, sound, envelope

	for close, tag, text in xml:gmatch("<(/?)([%w_]+)>([^<]*)") do
		if close == "" then
			local parent = stack[#stack]
			stack[#stack + 1] = tag

			if tag == "sounddef" then
				sounddef = {waveforms = {}}
			elseif tag == "waveform" and sounddef then
				waveform = {}
				sounddef.waveforms[#sounddef.waveforms + 1] = waveform
			elseif tag == "eventgroup" then
				groups[#groups + 1] = ""
			elseif tag == "event" then
				event = {layers = {}}
			elseif tag == "layer" and event then
				layer = {sounds = {}, envelopes = {}}
				event.layers[#event.layers + 1] = layer
			elseif tag == "sound" and layer then
				sound = {}
				layer.sounds[#layer.sounds + 1] = sound
			elseif tag == "envelope" and layer then
				envelope = {points = {}}
				layer.envelopes[#layer.envelopes + 1] = envelope
			elseif tag == "name" and parent == "sounddef" and sounddef then
				sounddef.name = text
			elseif tag == "name" and parent == "eventgroup" then
				groups[#groups] = text
			elseif tag == "name" and parent == "event" and event then
				event.name = text
			elseif parent == "sound" and sound then
				sound[tag] = text
			elseif parent == "envelope" and envelope then
				if tag == "point" then
					local x, y = text:match("^([^,]+),([^,]+)")
					envelope.points[#envelope.points + 1] = {tonumber(x), tonumber(y)}
				else
					envelope[tag] = text
				end
			elseif tag == "controlparameter" and parent == "layer" and layer then
				layer.control = text
			elseif parent == "waveform" and waveform then
				waveform[tag] = text
			elseif parent == "event" and event and NUMBER_FIELDS[tag] then
				event[tag] = tonumber(text)
			end
		else
			stack[#stack] = nil

			if tag == "sounddef" and sounddef then
				sounddefs[sounddef.name] = sounddef
				sounddef = nil
			elseif tag == "waveform" then
				waveform = nil
			elseif tag == "sound" then
				sound = nil
			elseif tag == "envelope" then
				envelope = nil
			elseif tag == "layer" then
				layer = nil
			elseif tag == "event" and event then
				events[(table.concat(groups, ":") .. ":" .. event.name):lower()] = event
				event = nil
			elseif tag == "eventgroup" then
				groups[#groups] = nil
			end
		end
	end

	return {sounddefs = sounddefs, events = events}
end

-- FSB3 and FSB4 keep 30 bytes of a sample's name, see goluwa/filesystem/files/fsb.lua
local function bank_entry_name(waveform_path)
	local name = file_path.GetFileNameFromPath(file_path.FixPathSlashes(waveform_path)):sub(1, 30)

	if not name:lower():ends_with(".wav") then name = name .. ".wav" end

	return name
end

do
	local projects = {}
	local banks = {}
	local resolved = {}
	local generation

	local function get_project(project_dir)
		local key = project_dir:lower()
		local project = projects[key]

		if project ~= nil then return project end

		local path = vfs.FindMixedCasePath(project_dir .. "/" .. file_path.GetFileNameFromPath(project_dir) .. ".fdp")
		project = path and fmod_events.ParseProject(assert(vfs.Read(path))) or false

		if not project then wlog("FMOD project %s not found", project_dir) end

		projects[key] = project
		return project
	end

	-- a bank inside a mounted pak is opened by its absolute path, mounts only resolve files of the archive they mount
	local function get_bank(project_dir, bank_name)
		local key = (project_dir .. "/" .. bank_name):lower()
		local bank = banks[key]

		if bank == nil then
			local path = vfs.FindMixedCasePath(project_dir .. "/" .. bank_name .. ".fsb")
			bank = path and vfs.GetAbsolutePath(path, false) or false
			banks[key] = bank
		end

		return bank or nil
	end

	function fmod_events.Get(name)
		if generation ~= vfs.mount_generation then
			generation = vfs.mount_generation
			projects = {}
			banks = {}
			resolved = {}
		end

		local cached = resolved[name]

		if cached ~= nil then return cached or nil end

		local project_dir, event_path = name:match("^(.-):(.+)$")
		local project = project_dir and get_project(project_dir)
		local event = project and project.events[event_path:lower()]

		if not event then
			if project then wlog("FMOD event %s not found", name) end

			resolved[name] = false
			return nil
		end

		local paths = {}
		local layers = {}

		for _, layer in ipairs(event.layers) do
			local sounds, envelopes = {}, {}

			for _, sound in ipairs(layer.sounds) do
				local sounddef = project.sounddefs[sound.name]
				local sound_paths = {}

				for _, waveform in ipairs(sounddef and sounddef.waveforms or {}) do
					local bank = get_bank(project_dir, waveform.soundbankname)
					local path = bank and vfs.FindMixedCasePath(bank .. "/" .. bank_entry_name(waveform.filename))

					if path then
						sound_paths[#sound_paths + 1] = path
						paths[#paths + 1] = path
					end
				end

				if sound_paths[1] then
					local from = tonumber(sound.x) or 0
					sounds[#sounds + 1] = {
						Paths = sound_paths,
						From = from,
						To = from + (tonumber(sound.width) or 1),
						Loop = sound.loopmode == "0",
					}
				end
			end

			for _, envelope in ipairs(layer.envelopes) do
				if envelope.dsp_name == "Volume" and envelope.points[1] then
					envelopes[#envelopes + 1] = {Parameter = envelope.parametername, Points = envelope.points}
				end
			end

			layers[#layers + 1] = {Control = layer.control, Sounds = sounds, Envelopes = envelopes}
		end

		if not paths[1] then
			wlog("FMOD event %s has no samples in the mounted sound banks", name)
			resolved[name] = false
			return nil
		end

		cached = {
			Paths = paths,
			Layers = layers,
			Volume = 10 ^ ((event.volume_db or 0) / 20),
			Pitch = event.pitch or 0,
			PitchRandomization = event.pitch_randomization or 0,
		}
		resolved[name] = cached
		return cached
	end
end

function fmod_events.GetPitch(event)
	return 2 ^ (
			event.Pitch + math.randomf(-event.PitchRandomization, event.PitchRandomization)
		)
end

do
	local function envelope_value(points, x)
		if x <= points[1][1] then return points[1][2] end

		for i = 2, #points do
			local a, b = points[i - 1], points[i]

			if x <= b[1] then
				return a[2] + (b[2] - a[2]) * (x - a[1]) / math.max(b[1] - a[1], 0.000001)
			end
		end

		return points[#points][2]
	end

	function fmod_events.Evaluate(event, parameters)
		local out = {}

		for layer_index, layer in ipairs(event.Layers) do
			local value = layer.Control and parameters[layer.Control] or 0
			local gain = 1

			for _, envelope in ipairs(layer.Envelopes) do
				local x = parameters[envelope.Parameter]

				if x then gain = gain * envelope_value(envelope.Points, x) end
			end

			if gain > 0 then
				for sound_index, sound in ipairs(layer.Sounds) do
					if value >= sound.From and value <= sound.To then
						out[#out + 1] = {
							Key = layer_index .. ":" .. sound_index,
							Paths = sound.Paths,
							Gain = gain,
							Loop = sound.Loop,
						}
					end
				end
			end
		end

		return out
	end
end

return fmod_events
