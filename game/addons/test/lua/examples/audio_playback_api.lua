HOTRELOAD = false
local ffi = require("ffi")
local sound = require("sound")
local audio_mixer = require("audio_mixer")
local event = require("event")
local system = require("system")
local ogg = require("codecs.ogg")
local fs = require("fs")

-- Load Ogg file and create a sound object from its PCM data
local function load_ogg(path)
	local data = assert(fs.read_file(path))
	local res = assert(ogg.Decode(data))
	print(" - Channels:", res.channels)
	print(" - Sample Rate:", res.sample_rate)
	print(" - Samples:", tonumber(res.samples))
	print(" - Vendor:", res.comments and res.comments.vendor or "N/A")
	local s = sound:CreateObject()
	s:SetName(path)
	s:SetVolume(1)
	s:SetBuffer(res.data)
	s:SetBufferLength(tonumber(res.samples))
	s:SetChannels(res.channels)
	s:SetSampleRate(res.sample_rate)
	s:SetLooping(false)
	-- Keep the buffer alive
	s.buffer_ref = res.data
	return s
end

local my_sound = load_ogg("test.ogg")
audio_mixer.Initialize()
audio_mixer.Play(my_sound)
local unref = system.KeepAlive("audio test")

event.AddListener("Update", "test", function()
	if not my_sound:IsPlaying() then
		print("Sound finished playing!")
		unref()
	end
end)