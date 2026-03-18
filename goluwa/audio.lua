local ffi = require("ffi")
local threads = import("goluwa/bindings/threads.lua")
local event = import("goluwa/event.lua")
local prototype = import("goluwa/prototype.lua")
local codec = import("goluwa/codec.lua")
local fs = import("goluwa/fs.lua")
local resource = import("goluwa/resource.lua")
local audio = {}
ffi.cdef[[
    typedef struct {
        void* buffer;           // float* pointer
        uint32_t buffer_len;    // number of samples
        float playback_pos;     // current sample position
        float volume;           // 0.0 to 1.0 (linear scaling for now; can be decibels)
        float pitch;            // 1.0 = normal, 2.0 = double
        uint8_t channels;       // 1 or 2
        bool looping;
        bool active;
        bool paused;
    } SoundState;

    typedef struct {
        SoundState slots[32];   // Max 32 simultaneous sounds for now
        float master_volume;
        bool shutdown;
    } MixerState;
]]
local mixer_state_t = ffi.typeof("MixerState")
local mixer_state_ptr_t = ffi.typeof("MixerState*")
audio.state = ffi.new(mixer_state_t)
audio.state_ref = audio.state
audio.state.master_volume = 1.0
audio.active_sounds = {}

function audio.GetFreeSlot()
	for i = 0, 31 do
		if not audio.state.slots[i].active then return i end
	end

	return nil
end

do
	local Sound = prototype.CreateTemplate("audio_sound")
	Sound:StartStorable()
	Sound:GetSet("Volume", 1)
	Sound:GetSet("Pitch", 1)
	Sound:IsSet("Looping", false)
	Sound:EndStorable()
	Sound:GetSet("Buffer", nil)
	Sound:GetSet("BufferLength", 0)
	Sound:GetSet("Channels", 2)
	Sound:GetSet("SampleRate", 44100)
	Sound:GetSet("PlaybackPosition", 0)
	Sound:IsSet("Playing", false)
	Sound:IsSet("Paused", false)
	Sound:IsSet("Ready", false)

	function Sound:GetDuration() -- in seconds
		local buffer_len = self:GetBufferLength()
		local channels = self:GetChannels()
		local sample_rate = self:GetSampleRate()

		if channels <= 0 then channels = 2 end

		if sample_rate <= 0 then sample_rate = 44100 end

		return buffer_len / (channels * sample_rate)
	end

	function Sound:MakeReady()
		self:SetReady(true)
		self:SetPlaying(false)
		self:SetPaused(false)
		self:SetPlaybackPosition(0)
	end

	function Sound:LoadPath(path)
		local function load(res, full_path)
			self:SetName(path)
			self:SetVolume(1)
			self:SetBuffer(res.data)
			self:SetBufferLength(tonumber(res.samples))
			self:SetChannels(res.channels)
			self:SetSampleRate(res.sample_rate)
			self:SetLooping(false)
			-- Keep the buffer alive
			self.buffer_ref = res.data
			self:MakeReady()

			if self.play_on_ready then
				self.play_on_ready = nil
				self:Play()
			end
		end

		resource.Download(path):Then(function(full_path)
			local ogg, err = codec.ReadFile("ogg", full_path)

			if not ogg then
				print("failed to decode sound:", full_path, err)
				return
			end

			load(ogg, full_path)
		end):Catch(function(err)
			print("failed to download sound:", full_path, err)
			self:MakeReady()
		end)
	end

	function Sound:Play()
		if not self:IsReady() or not self:GetBuffer() then
			self.play_on_ready = true
			return nil
		end

		local slot = audio.GetFreeSlot()

		if not slot then return nil end

		self:SetPlaying(true)
		self:SetPaused(false)
		local state = audio.state.slots[slot]
		state.buffer = ffi.cast("void*", self:GetBuffer())
		state.buffer_len = self:GetBufferLength()
		state.playback_pos = 0.0
		state.volume = self:GetVolume()
		state.pitch = self:GetPitch()
		state.channels = self:GetChannels()
		state.looping = self:IsLooping()
		state.paused = false
		state.active = true
		audio.active_sounds[slot] = self
		return slot
	end

	function Sound:Start()
		self:SetPlaying(true)
		self:SetPaused(false)
		self:SetPlaybackPosition(0)
	end

	function Sound:Stop()
		self:SetPlaying(false)
		self:SetPaused(false)
		self:SetPlaybackPosition(0)
	end

	function Sound:Pause()
		if self:IsPlaying() then self:SetPaused(true) end
	end

	function Sound:Resume()
		if self:IsPaused() then self:SetPaused(false) end
	end

	function Sound:__tostring2()
		return (
			" %s | %.2f%%"
		):format(self:GetName(), (self:GetPlaybackPosition() / self:GetBufferLength()) * 100)
	end

	Sound = Sound:Register()

	function audio.CreateSound()
		return Sound:CreateObject()
	end

	function audio.LoadSound(path)
		local s = Sound:CreateObject()
		s:LoadPath(path)
		return s
	end
end

function audio.StopAll()
	for i = 0, 31 do
		audio.state.slots[i].active = false
		audio.active_sounds[i] = nil
	end
end

event.AddListener("Update", "audio_sync", function()
	for slot, sound_obj in pairs(audio.active_sounds) do
		local state = audio.state.slots[slot]

		if not state.active then
			audio.active_sounds[slot]:Remove()
			audio.active_sounds[slot] = nil
			sound_obj:SetPlaying(false)
		elseif not sound_obj:IsPlaying() then
			state.active = false
			audio.active_sounds[slot]:Remove()
			audio.active_sounds[slot] = nil
		else
			state.volume = sound_obj:GetVolume()
			state.pitch = sound_obj:GetPitch()
			state.paused = sound_obj:IsPaused()
			sound_obj:SetPlaybackPosition(state.playback_pos)
		end
	end
end)

local function mixer_worker(shared_state_ptr)
	local ffi = require("ffi")
	local audio_buffer = import("goluwa/bindings/audio_buffer.lua")
	local threads = import("goluwa/bindings/threads.lua")
	ffi.cdef[[
		typedef struct {
			void* buffer;           // float* pointer
			uint32_t buffer_len;    // number of samples
			float playback_pos;     // current sample position
			float volume;           // 0.0 to 1.0 (linear scaling for now; can be decibels)
			float pitch;            // 1.0 = normal, 2.0 = double
			uint8_t channels;       // 1 or 2
			bool looping;
			bool active;
			bool paused;
		} SoundState;

		typedef struct {
			SoundState slots[32];   // Max 32 simultaneous sounds for now
			float master_volume;
			bool shutdown;
		} MixerState;
	]]
	local state = ffi.cast("MixerState*", shared_state_ptr)
	local config = audio_buffer.start{
		sample_rate = 44100,
		buffer_size = 512,
		channels = 2,
	}

	function audio_buffer.callback(out_buffer, num_samples, config)
		for i = 0, num_samples - 1 do
			out_buffer[i] = 0
		end

		local master_volume = state.master_volume

		for i = 0, 31 do
			local s = state.slots[i]

			if s.active and not s.paused then
				local samples = ffi.cast("float*", s.buffer)
				local pos = s.playback_pos
				local pitch = s.pitch
				local vol = s.volume * master_volume
				local len = s.buffer_len

				for j = 0, num_samples - 1, 2 do
					local idx = math.floor(pos)

					if idx >= len then
						if s.looping then
							pos = 0
							idx = 0
						else
							s.active = false

							break
						end
					end

					if s.channels == 2 then
						out_buffer[j] = out_buffer[j] + (samples[idx * 2] * vol)
						out_buffer[j + 1] = out_buffer[j + 1] + (samples[idx * 2 + 1] * vol)
					else
						out_buffer[j] = out_buffer[j] + (samples[idx] * vol)
						out_buffer[j + 1] = out_buffer[j + 1] + (samples[idx] * vol)
					end

					pos = pos + pitch
				end

				s.playback_pos = pos
			end
		end
	end

	while not state.shutdown do
		audio_buffer.update()
	end

	audio_buffer.stop()
end

function audio.Initialize()
	if audio.thread then return end

	audio.thread = threads.new(mixer_worker)
	audio.thread:run(audio.state, true)

	import("goluwa/timer.lua").Delay(0.1, function()
		if
			audio.thread and
			audio.thread.input_data and
			audio.thread.input_data.status == threads.STATUS_ERROR
		then
			local ok, err = audio.thread:join()

			if not ok and err then
				logn("Audio mixer thread initialization error: ", err)
			end
		end
	end)
end

function audio.Shutdown()
	if audio.thread then
		audio.state.shutdown = true
		local ok, err = audio.thread:join()

		if not ok and err then
			error("Audio mixer thread error: " .. tostring(err))
		end

		audio.thread = nil
	end
end

event.AddListener("ShutDown", "audio_shutdown", function()
	audio.Shutdown()
end)

return audio
