local ffi = require("ffi")
local threads = require("bindings.threads")
local event = require("event")
local sound = require("sound")
local audio_mixer = {}
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
audio_mixer.state = ffi.new(mixer_state_t)
audio_mixer.state_ref = audio_mixer.state
audio_mixer.state.master_volume = 1.0
audio_mixer.active_sounds = {}

function audio_mixer.GetFreeSlot()
	for i = 0, 31 do
		if not audio_mixer.state.slots[i].active then return i end
	end

	return nil
end

function audio_mixer.Play(sound_obj)
	local slot = audio_mixer.GetFreeSlot()

	if not slot then return nil end

	sound_obj:SetPlaying(true)
	sound_obj:SetPaused(false)
	local state = audio_mixer.state.slots[slot]
	state.buffer = ffi.cast("void*", sound_obj:GetBuffer())
	state.buffer_len = sound_obj:GetBufferLength()
	state.playback_pos = 0.0
	state.volume = sound_obj:GetVolume()
	state.pitch = sound_obj:GetPitch()
	state.channels = sound_obj:GetChannels()
	state.looping = sound_obj:IsLooping()
	state.paused = false
	state.active = true
	audio_mixer.active_sounds[slot] = sound_obj
	return slot
end

function audio_mixer.StopAll()
	for i = 0, 31 do
		audio_mixer.state.slots[i].active = false
		audio_mixer.active_sounds[i] = nil
	end
end

event.AddListener("Update", "audio_mixer_sync", function()
	for slot, sound_obj in pairs(audio_mixer.active_sounds) do
		local state = audio_mixer.state.slots[slot]

		if not state.active then
			audio_mixer.active_sounds[slot] = nil
			sound_obj:SetPlaying(false)
		elseif not sound_obj:IsPlaying() then
			state.active = false
			audio_mixer.active_sounds[slot] = nil
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
	local audio = require("bindings.audio")
	local threads = require("bindings.threads")
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
	local config = audio.start({
		sample_rate = 44100,
		buffer_size = 512,
		channels = 2,
	})

	function audio.callback(out_buffer, num_samples, config)
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
		audio.update()
	end

	audio.stop()
end

function audio_mixer.Initialize()
	if audio_mixer.thread then return end

	audio_mixer.thread = threads.new(mixer_worker)
	audio_mixer.thread:run(audio_mixer.state, true)

	require("timer").Delay(0.1, function()
		if
			audio_mixer.thread and
			audio_mixer.thread.input_data and
			audio_mixer.thread.input_data.status == threads.STATUS_ERROR
		then
			local ok, err = audio_mixer.thread:join()

			if not ok and err then
				logn("Audio mixer thread initialization error: ", err)
			end
		end
	end)
end

function audio_mixer.Shutdown()
	if audio_mixer.thread then
		audio_mixer.state.shutdown = true
		local ok, err = audio_mixer.thread:join()

		if not ok and err then
			error("Audio mixer thread error: " .. tostring(err))
		end

		audio_mixer.thread = nil
	end
end

event.AddListener("ShutDown", "audio_mixer_shutdown", function()
	audio_mixer.Shutdown()
end)

return audio_mixer