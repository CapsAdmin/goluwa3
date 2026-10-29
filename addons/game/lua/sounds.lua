local event = import("goluwa/event.lua")
local vfs = import("goluwa/filesystem/vfs.lua")
local resource = import("goluwa/resource.lua")
local audio = AUDIO and import("goluwa/audio.lua")
local render3d = RENDER_3D and import("goluwa/render3d/render3d.lua")
local sounds = {}
local VOICES = 3
local REFERENCE_DISTANCE = 2
local AUDIBLE = 10 ^ (-45 / 20)
local voices = {}
local missing = {}

function sounds.CreateSource(path)
	if missing[path] then return end

	local full_path = "sound/" .. path

	if not vfs.IsFile(full_path) then
		missing[path] = true
		return
	end

	resource.skip_providers = true
	local source = audio.CreateSource(full_path)
	resource.skip_providers = false
	source:SetNormalized(true)
	source:SetReferenceDistance(REFERENCE_DISTANCE)
	return source
end

function sounds.GetLevel(position, volume)
	return volume * REFERENCE_DISTANCE / math.max(position:Distance(audio.GetListenerPosition()), REFERENCE_DISTANCE)
end

function sounds.IsAudible(position, volume)
	return sounds.GetLevel(position, volume) >= AUDIBLE
end

local function get_voice(path)
	local entry = voices[path]

	if not entry then
		if missing[path] then return end

		local first = sounds.CreateSource(path)

		if not first then return end

		entry = {first, next = 1}

		for i = 2, VOICES do
			entry[i] = sounds.CreateSource(path)
		end

		voices[path] = entry
	end

	local voice = entry[entry.next]
	entry.next = entry.next % VOICES + 1
	return voice
end

function sounds.Play(path, position, volume, pitch)
	if not audio or not CLIENT then return end

	volume = volume or 1

	if not sounds.IsAudible(position, volume) then return end

	local voice = get_voice(path)

	if not voice then return end

	voice:SetGain(volume)
	voice:SetPitch(pitch or 1)
	voice:SetPosition(position:Copy())
	voice:Play()
end

function sounds.PlayRandom(paths, position, volume, pitch)
	if paths then
		sounds.Play(paths[math.random(#paths)], position, volume, pitch)
	end
end

if audio and RENDER_3D then
	event.AddListener("Update", "sounds_listener", function()
		local camera = render3d.GetCamera()
		local rotation = camera:GetRotation()
		audio.SetListenerPosition(camera:GetPosition():Copy())
		audio.SetListenerOrientation(rotation:GetForward(), rotation:GetUp())
	end)
end

return sounds
