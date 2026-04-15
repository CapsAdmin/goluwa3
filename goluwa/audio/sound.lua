local ffi = require("ffi")
local prototype = import("goluwa/prototype.lua")
local codec = import("goluwa/codec.lua")
local resource = import("goluwa/resource.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local module = {}

function module.Attach(audio)
	local clamp = math.clamp

	local function configure_sound_buffer(sound, data, buffer_length, channels, sample_rate)
		if not data then return false end

		sound:SetBuffer(data)
		sound:SetBufferLength(tonumber(buffer_length) or 0)
		sound:SetChannels(tonumber(channels) or 2)
		sound:SetSampleRate(tonumber(sample_rate) or 44100)
		sound.buffer_ref = data
		sound:MakeReady()
		return true
	end

	local function extract_sound_config(var)
		if not var then return end

		if type(var) == "cdata" then
			return {data = var, buffer_length = 0, channels = 2, sample_rate = 44100}
		end

		if type(var) ~= "table" then return end

		if var.data and var.samples then
			return {
				data = var.data,
				buffer_length = var.samples,
				channels = var.channels,
				sample_rate = var.sample_rate,
			}
		end

		if var.decoded_data then
			local info = var.info or {}
			return {
				data = var.decoded_data,
				buffer_length = var.length or var.sample_count or info.length or 0,
				channels = info.channels or var.channels,
				sample_rate = info.samplerate or info.sample_rate or var.sample_rate,
			}
		end

		if var.getPointer and var.getSampleCount then
			return {
				data = var:getPointer(),
				buffer_length = var:getSampleCount(),
				channels = var.getChannels and var:getChannels() or 2,
				sample_rate = var.getSampleRate and var:getSampleRate() or 44100,
				buffer = var.buffer,
			}
		end

		if var.GetData then
			return {
				data = var:GetData(),
				buffer_length = var.GetLength and var:GetLength() or 0,
				channels = var.GetChannels and var:GetChannels() or 2,
				sample_rate = var.GetSampleRate and var:GetSampleRate() or 44100,
				buffer = var,
			}
		end
	end

	local function apply_sound_spatial_state(sound, state)
		local position = sound:GetPosition()
		local velocity = sound:GetVelocity()
		local direction = sound:GetDirection()
		state.position_x = position.x
		state.position_y = position.y
		state.position_z = position.z
		state.velocity_x = velocity.x
		state.velocity_y = velocity.y
		state.velocity_z = velocity.z
		state.direction_x = direction.x
		state.direction_y = direction.y
		state.direction_z = direction.z
		state.inner_cone_angle = sound:GetInnerConeAngle()
		state.outer_cone_angle = sound:GetOuterConeAngle()
		state.outer_cone_gain = sound:GetOuterConeGain()
		state.reference_distance = sound:GetReferenceDistance()
		state.max_distance = sound:GetMaxDistance()
		state.rolloff_factor = sound:GetRolloffFactor()
		return state
	end

	local function sync_active_sound_state(sound)
		if sound.slot == nil then return end

		local state = audio.state.slots[sound.slot]
		state.volume = sound:GetVolume()
		state.pitch = sound:GetPitch()
		state.looping = sound:IsLooping()
		state.paused = sound:IsPaused()
		apply_sound_spatial_state(sound, state)
	end

	local function clear_sound_slot(sound, reset_position)
		if not sound or sound.slot == nil then return end

		local slot = sound.slot
		local state = audio.state.slots[slot]
		state.active = false
		state.paused = false
		sound.slot = nil
		audio.active_sounds[slot] = nil
		sound:SetPlaying(false)
		sound:SetPaused(false)

		if reset_position then
			sound:SetPlaybackPosition(0)
		else
			sound:SetPlaybackPosition(state.playback_pos)
		end
	end

	local function get_sound_current_sample_info(sound)
		local buffer = sound and sound:GetBuffer()
		local buffer_length = sound and tonumber(sound:GetBufferLength()) or 0
		local channels = math.max(tonumber(sound and sound:GetChannels()) or 1, 1)
		local playback_position = tonumber(sound and sound:GetPlaybackPosition()) or 0
		local sample_index = math.floor(clamp(playback_position, 0, math.max(buffer_length - 1, 0)))
		local sample_window = 64
		local info = {
			index = sample_index,
			playback_position = playback_position,
			window = sample_window,
			raw_left = 0,
			raw_right = 0,
			raw_mono = 0,
			raw_peak = 0,
			left = 0,
			right = 0,
			peak = 0,
			active = sound and sound:IsPlaying() or false,
		}

		if not buffer or buffer_length <= 0 then return info end

		local samples = ffi.cast("float*", buffer)

		if channels >= 2 then
			info.raw_left = tonumber(samples[sample_index * 2]) or 0
			info.raw_right = tonumber(samples[sample_index * 2 + 1]) or 0
			info.raw_mono = (info.raw_left + info.raw_right) * 0.5
		else
			info.raw_mono = tonumber(samples[sample_index]) or 0
			info.raw_left = info.raw_mono
			info.raw_right = info.raw_mono
		end

		local window_end = math.min(sample_index + sample_window - 1, buffer_length - 1)

		for i = sample_index, window_end do
			local left
			local right

			if channels >= 2 then
				left = tonumber(samples[i * 2]) or 0
				right = tonumber(samples[i * 2 + 1]) or 0
			else
				left = tonumber(samples[i]) or 0
				right = left
			end

			info.raw_peak = math.max(info.raw_peak, math.abs(left), math.abs(right))
		end

		if not info.active then return info end

		local mix = audio._ComputeSpatialMixData and
			audio._ComputeSpatialMixData(sound) or
			{
				total_gain = 1,
				left_gain = 1,
				right_gain = 1,
			}
		local source_gain = (
				tonumber(sound:GetVolume()) or
				1
			) * (
				tonumber(audio.state.master_volume) or
				1
			) * (
				tonumber(mix.total_gain) or
				1
			)
		info.left = info.raw_left * source_gain * (tonumber(mix.left_gain) or 1)
		info.right = info.raw_right * source_gain * (tonumber(mix.right_gain) or 1)
		info.peak = info.raw_peak * source_gain * math.max(math.abs(tonumber(mix.left_gain) or 1), math.abs(tonumber(mix.right_gain) or 1))
		info.total_gain = source_gain
		info.mix = mix
		return info
	end

	audio._apply_sound_spatial_state = apply_sound_spatial_state
	audio._sync_active_sound_state = sync_active_sound_state
	audio._clear_sound_slot = clear_sound_slot
	audio._get_sound_current_sample_info = get_sound_current_sample_info
	local Sound = prototype.CreateTemplate("audio_sound")
	Sound:StartStorable()
	Sound:GetSet("Volume", 1)
	Sound:GetSet("Pitch", 1)
	Sound:IsSet("Looping", false)
	Sound:EndStorable()
	Sound:GetSet("Buffer", nil)
	Sound:GetSet("BufferLength", 0)
	Sound:GetSet("Channels", 2)
	Sound:GetSet("Channel", 1)
	Sound:GetSet("SampleRate", 44100)
	Sound:GetSet("PlaybackPosition", 0)
	Sound:IsSet("Playing", false)
	Sound:IsSet("Paused", false)
	Sound:IsSet("Ready", false)
	Sound:GetSet("InnerConeAngle", 360)
	Sound:GetSet("OuterConeAngle", 360)
	Sound:GetSet("OuterConeGain", 0)
	Sound:GetSet("ReferenceDistance", 1)
	Sound:GetSet("MaxDistance", 1000000)
	Sound:GetSet("RolloffFactor", 1)
	Sound:GetSet("Direction", Vec3(0, 0, 0))
	Sound:GetSet("Position", Vec3(0, 0, 0))
	Sound:GetSet("Velocity", Vec3(0, 0, 0))

	function Sound:GetDuration()
		local buffer_len = self:GetBufferLength()
		local sample_rate = self:GetSampleRate()

		if sample_rate <= 0 then sample_rate = 44100 end

		return buffer_len / sample_rate
	end

	function Sound:MakeReady()
		self:SetReady(true)
		self:SetPlaying(false)
		self:SetPaused(false)
		self:SetPlaybackPosition(0)
	end

	function Sound:LoadPath(path)
		local function load(res)
			self:SetName(path)
			self:SetVolume(self:GetVolume())
			configure_sound_buffer(self, res.data, res.samples, res.channels, res.sample_rate)
			self:SetLooping(false)

			if self.play_on_ready then
				local playback_position = self.play_on_ready.position or 0
				self.play_on_ready = nil
				self:Play(playback_position)
			end
		end

		resource.Download(path):Then(function(full_path)
			local decoded, err = codec.DecodeFile(full_path)

			if not decoded then
				print("failed to decode sound:", full_path, err)
				self:MakeReady()
				return
			end

			load(decoded)
		end):Catch(function(err)
			print("failed to download sound:", path, err)
			self:MakeReady()
		end)
	end

	function Sound:ApplySlotState(state)
		state.buffer = ffi.cast("void*", self:GetBuffer())
		state.buffer_len = self:GetBufferLength()
		state.playback_pos = self:GetPlaybackPosition()
		state.volume = self:GetVolume()
		state.pitch = self:GetPitch()
		state.channels = self:GetChannels()
		state.looping = self:IsLooping()
		state.paused = self:IsPaused()
		apply_sound_spatial_state(self, state)
		state.active = true
	end

	function Sound:Play(start_position)
		if not self:IsReady() or not self:GetBuffer() then
			self.play_on_ready = {position = tonumber(start_position) or 0}
			return nil
		end

		clear_sound_slot(self, false)
		self:SetPlaybackPosition(clamp(tonumber(start_position) or 0, 0, self:GetBufferLength()))
		local slot = audio.GetFreeSlot()

		if not slot then return nil end

		self:SetPlaying(true)
		self:SetPaused(false)
		local state = audio.state.slots[slot]
		self:ApplySlotState(state)
		self.slot = slot
		audio.active_sounds[slot] = self
		return slot
	end

	function Sound:Start()
		return self:Play(0)
	end

	function Sound:Stop()
		clear_sound_slot(self, true)
	end

	function Sound:Pause()
		if not self:IsPlaying() then return end

		self:SetPaused(true)

		if self.slot ~= nil then audio.state.slots[self.slot].paused = true end
	end

	function Sound:Resume()
		if not self:IsPaused() then return end

		self:SetPaused(false)

		if self.slot ~= nil and audio.state.slots[self.slot].active then
			audio.state.slots[self.slot].paused = false
			self:SetPlaying(true)
			return self.slot
		end

		return self:Play(self:GetPlaybackPosition())
	end

	function Sound:Rewind()
		self:SetPlaybackPosition(0)

		if self.slot ~= nil then audio.state.slots[self.slot].playback_pos = 0 end
	end

	function Sound:Seek(offset, unit)
		local playback_position

		if unit == "samples" then
			playback_position = tonumber(offset) or 0
		else
			playback_position = (tonumber(offset) or 0) * self:GetSampleRate()
		end

		playback_position = clamp(playback_position, 0, self:GetBufferLength())
		self:SetPlaybackPosition(playback_position)

		if self.slot ~= nil then
			audio.state.slots[self.slot].playback_pos = playback_position
		end

		return self:Tell(unit)
	end

	function Sound:Tell(unit_or_wrapper, maybe_unit)
		local unit = maybe_unit or unit_or_wrapper
		local playback_position = self:GetPlaybackPosition()

		if unit == "samples" then return playback_position end

		return playback_position / self:GetSampleRate()
	end

	function Sound:SetGain(gain)
		self:SetVolume(gain)

		if self.slot ~= nil then
			audio.state.slots[self.slot].volume = self:GetVolume()
		end
	end

	function Sound:GetGain()
		return self:GetVolume()
	end

	function Sound:GetLooping()
		return self:IsLooping()
	end

	function Sound:IsPlaying()
		if self.slot == nil then return false end

		local state = audio.state.slots[self.slot]
		return state.active and not state.paused
	end

	function Sound:SetPitch(pitch)
		pitch = tonumber(pitch) or 1
		self.Pitch = pitch

		if self.slot ~= nil then audio.state.slots[self.slot].pitch = pitch end
	end

	function Sound:SetLooping(looping)
		looping = not not looping
		self.Looping = looping

		if self.slot ~= nil then audio.state.slots[self.slot].looping = looping end
	end

	function Sound:SetBuffer(buffer)
		self.buffer_view = buffer

		if type(buffer) == "table" and buffer.GetData then
			self.Buffer = buffer:GetData()

			if buffer.GetLength then self:SetBufferLength(buffer:GetLength()) end

			if buffer.GetChannels then self:SetChannels(buffer:GetChannels()) end

			if buffer.GetSampleRate then self:SetSampleRate(buffer:GetSampleRate()) end

			return
		end

		self.Buffer = buffer
	end

	function Sound:GetBufferView()
		return self.buffer_view
	end

	function Sound:SetChannel(channel)
		self.Channel = tonumber(channel) or 1
	end

	function Sound:GetDirection()
		return self.Direction
	end

	function Sound:SetDirection(direction, ...)
		if select("#", ...) > 0 then
			error("SetDirection expects a Vec3-like value", 2)
		end

		self.Direction = Vec3.FromValue(direction)
		sync_active_sound_state(self)
		return self
	end

	function Sound:GetPosition()
		return self.Position
	end

	function Sound:SetPosition(position, ...)
		if select("#", ...) > 0 then
			error("SetPosition expects a Vec3-like value", 2)
		end

		self.Position = Vec3.FromValue(position)
		sync_active_sound_state(self)
		return self
	end

	function Sound:GetVelocity()
		return self.Velocity
	end

	function Sound:SetVelocity(velocity, ...)
		if select("#", ...) > 0 then
			error("SetVelocity expects a Vec3-like value", 2)
		end

		self.Velocity = Vec3.FromValue(velocity)
		sync_active_sound_state(self)
		return self
	end

	function Sound:SetReferenceDistance(distance)
		self.ReferenceDistance = tonumber(distance) or 1
		sync_active_sound_state(self)
	end

	function Sound:SetInnerConeAngle(angle)
		self.InnerConeAngle = clamp(tonumber(angle) or 360, 0, 360)
		sync_active_sound_state(self)
	end

	function Sound:SetOuterConeAngle(angle)
		self.OuterConeAngle = clamp(tonumber(angle) or 360, 0, 360)
		sync_active_sound_state(self)
	end

	function Sound:SetOuterConeGain(gain)
		self.OuterConeGain = clamp(tonumber(gain) or 0, 0, 1)
		sync_active_sound_state(self)
	end

	function Sound:SetCone(inner_angle, outer_angle, outer_gain)
		self:SetInnerConeAngle(inner_angle)
		self:SetOuterConeAngle(outer_angle)
		self:SetOuterConeGain(outer_gain)
		return self
	end

	function Sound:SetMaxDistance(distance)
		self.MaxDistance = tonumber(distance) or 1000000
		sync_active_sound_state(self)
	end

	function Sound:SetRolloffFactor(factor)
		self.RolloffFactor = tonumber(factor) or 1
		sync_active_sound_state(self)
	end

	function Sound:IsStopped()
		return not self:IsPlaying() and not self:IsPaused()
	end

	function Sound:GetSampleCount()
		return self:GetBufferLength()
	end

	function Sound:GetCurrentSampleInfo()
		return get_sound_current_sample_info(self)
	end

	function Sound:GetCurrentSampleValue()
		return get_sound_current_sample_info(self).raw_mono
	end

	function Sound:GetCurrentSampleStereoVolume()
		local info = get_sound_current_sample_info(self)
		return info.left, info.right
	end

	function Sound:GetCurrentSampleVolume()
		return get_sound_current_sample_info(self).peak
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

	function audio.CreateSource(var)
		local sound = audio.CreateSound()

		if type(var) == "string" then
			sound:SetName(var)
			sound:LoadPath(var)
			return sound
		end

		local config = extract_sound_config(var)

		if config then
			configure_sound_buffer(sound, config.data, config.buffer_length, config.channels, config.sample_rate)

			if config.buffer then sound:SetBuffer(config.buffer) end
		end

		return sound
	end

	function audio.LoadSound(path)
		return audio.CreateSource(path)
	end

	function audio.GetCurrentSampleInfo(sound)
		if not sound then return end

		return get_sound_current_sample_info(sound)
	end

	return audio
end

return module
