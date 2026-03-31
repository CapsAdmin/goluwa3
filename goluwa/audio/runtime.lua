local event = import("goluwa/event.lua")
local module = {}

function module.Attach(audio)
	function audio.GetFreeSlot()
		for i = 0, 31 do
			if not audio.state.slots[i].active then return i end
		end

		return nil
	end

	function audio.StopAll()
		for i = 0, 31 do
			local sound = audio.active_sounds[i]

			if sound then
				audio._clear_sound_slot(sound, true)
			else
				audio.state.slots[i].active = false
				audio.state.slots[i].paused = false
				audio.active_sounds[i] = nil
			end
		end
	end

	function audio.SetDistanceModel(name)
		audio.distance_model = audio.DISTANCE_MODE_IDS[name] and name or "inverse"
		audio.sync_listener_state()
	end

	function audio.GetDistanceModel()
		return audio.distance_model
	end

	function audio.SetListenerPosition(x, y, z)
		audio.listener_position[1] = tonumber(x) or 0
		audio.listener_position[2] = tonumber(y) or 0
		audio.listener_position[3] = tonumber(z) or 0
		audio.sync_listener_state()
	end

	function audio.GetListenerPosition()
		return unpack(audio.listener_position)
	end

	function audio.SetListenerVelocity(x, y, z)
		audio.listener_velocity[1] = tonumber(x) or 0
		audio.listener_velocity[2] = tonumber(y) or 0
		audio.listener_velocity[3] = tonumber(z) or 0
		audio.sync_listener_state()
	end

	function audio.GetListenerVelocity()
		return unpack(audio.listener_velocity)
	end

	function audio.SetListenerOrientation(x, y, z, x2, y2, z2)
		audio.listener_orientation[1] = tonumber(x) or 0
		audio.listener_orientation[2] = tonumber(y) or 0
		audio.listener_orientation[3] = tonumber(z) or -1
		audio.listener_orientation[4] = tonumber(x2) or 0
		audio.listener_orientation[5] = tonumber(y2) or 1
		audio.listener_orientation[6] = tonumber(z2) or 0
		audio.sync_listener_state()
	end

	function audio.GetListenerOrientation()
		return unpack(audio.listener_orientation)
	end

	function audio.SetDopplerFactor(factor)
		audio.doppler_factor = math.max(tonumber(factor) or 1, 0)
		audio.sync_listener_state()
	end

	function audio.GetDopplerFactor()
		return audio.doppler_factor
	end

	function audio.SetSpeedOfSound(speed)
		audio.speed_of_sound = math.max(tonumber(speed) or 343.3, 0.0001)
		audio.sync_listener_state()
	end

	function audio.GetSpeedOfSound()
		return audio.speed_of_sound
	end

	function audio.SetListenerGain(gain)
		audio.state.master_volume = tonumber(gain) or 1
		audio.sync_listener_state()
	end

	function audio.GetListenerGain()
		return audio.state.master_volume
	end

	event.AddListener("Update", "audio_sync", function()
		for slot, sound_obj in pairs(audio.active_sounds) do
			local state = audio.state.slots[slot]

			if not state.active then
				sound_obj:SetPlaybackPosition(state.playback_pos)

				if sound_obj.slot == slot then sound_obj.slot = nil end

				audio.active_sounds[slot] = nil
				sound_obj:SetPlaying(false)
				sound_obj:SetPaused(false)
			elseif not sound_obj:IsPlaying() then
				state.active = false
				state.paused = false

				if sound_obj.slot == slot then sound_obj.slot = nil end

				audio.active_sounds[slot] = nil
			else
				audio._sync_active_sound_state(sound_obj)
				sound_obj:SetPlaybackPosition(state.playback_pos)
			end
		end
	end)

	return audio
end

return module
