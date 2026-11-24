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
	local sounddef, waveform, event

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
				event = {sounds = {}}
			elseif tag == "name" and parent == "sounddef" and sounddef then
				sounddef.name = text
			elseif tag == "name" and parent == "eventgroup" then
				groups[#groups] = text
			elseif tag == "name" and parent == "event" and event then
				event.name = text
			elseif tag == "name" and parent == "sound" and event then
				event.sounds[#event.sounds + 1] = text
			elseif parent == "waveform" and waveform then
				waveform[tag] = text
			elseif parent == "event" and event and NUMBER_FIELDS[tag] then
				event[tag] = tonumber(text)
			elseif parent == "sounddef" and sounddef and tag == "volume_db" then
				sounddef.volume_db = tonumber(text)
			end
		else
			stack[#stack] = nil

			if tag == "sounddef" and sounddef then
				sounddefs[sounddef.name] = sounddef
				sounddef = nil
			elseif tag == "waveform" then
				waveform = nil
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
		local volume_db = event.volume_db or 0

		for _, sound_name in ipairs(event.sounds) do
			local sounddef = project.sounddefs[sound_name]

			for _, waveform in ipairs(sounddef and sounddef.waveforms or {}) do
				local bank = get_bank(project_dir, waveform.soundbankname)
				local path = bank and vfs.FindMixedCasePath(bank .. "/" .. bank_entry_name(waveform.filename))

				if path then paths[#paths + 1] = path end
			end
		end

		if not paths[1] then
			wlog("FMOD event %s has no samples in the mounted sound banks", name)
			resolved[name] = false
			return nil
		end

		cached = {
			Paths = paths,
			Volume = 10 ^ (volume_db / 20),
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

return fmod_events
