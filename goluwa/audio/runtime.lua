local event = import("goluwa/event.lua")
local clock = import("goluwa/audio/clock.lua")
local module = {}

function module.Attach(audio)
	audio.clock = clock

	function audio.GetFreeSlot()
		for i = 0, audio.SLOT_COUNT - 1 do
			local slot = audio.state.slots[i]

			if not slot.active and not slot.draining then return i end
		end

		return nil
	end

	function audio.StopAll()
		for i = 0, audio.SLOT_COUNT - 1 do
			local sound = audio.active_sounds[i]

			if sound then
				audio._clear_sound_slot(sound, true, true)
			else
				local slot = audio.state.slots[i]
				slot.active = false
				slot.paused = false
				slot.draining = false
				slot.start_serial = slot.start_serial + 1
			end
		end
	end

	function audio.SetDistanceModel(name)
		audio.distance_model = audio.DISTANCE_MODE_IDS[name] and name or "inverse"
	end

	function audio.GetDistanceModel()
		return audio.distance_model
	end

	function audio.SetListenerPosition(position)
		audio.listener_position = position
	end

	function audio.GetListenerPosition()
		return audio.listener_position
	end

	function audio.GetListenerVelocity()
		return audio.listener_motion.velocity
	end

	function audio.SetListenerOrientation(forward, up)
		audio.listener_forward = forward
		audio.listener_up = up
	end

	function audio.GetListenerOrientation()
		return audio.listener_forward, audio.listener_up
	end

	function audio.SetDopplerFactor(factor)
		audio.doppler_factor = math.max(factor, 0)
	end

	function audio.GetDopplerFactor()
		return audio.doppler_factor
	end

	function audio.SetSpeedOfSound(speed)
		audio.speed_of_sound = math.max(speed, 0.0001)
	end

	function audio.GetSpeedOfSound()
		return audio.speed_of_sound
	end

	function audio.SetListenerGain(gain)
		audio.state.master_volume = gain
	end

	function audio.GetListenerGain()
		return audio.state.master_volume
	end

	function audio.Update()
		local time = audio.clock()
		audio.UpdateListenerMotion(time)

		for slot, sound in pairs(audio.active_sounds) do
			local state = audio.state.slots[slot]

			if not state.active then
				sound:SetPlaybackPosition(state.playback_pos)

				if sound.slot == slot then sound.slot = nil end

				audio.active_sounds[slot] = nil
				sound:SetPlaying(false)
				sound:SetPaused(false)
			elseif not sound:IsPlaying() then
				state.draining = state.spatial
				state.active = false
				state.paused = false

				if sound.slot == slot then sound.slot = nil end

				audio.active_sounds[slot] = nil
			else
				audio._sync_active_sound_state(sound)
				sound:SetPlaybackPosition(state.playback_pos)
				audio.UpdateSoundPaths(sound, time)
			end
		end
	end

	event.AddListener("Update", "audio_sync", audio.Update)
	return audio
end

return module
