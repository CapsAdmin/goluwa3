local event = import("goluwa/event.lua")
local clock = import("goluwa/audio/clock.lua")
local spatial_air = import("goluwa/audio/spatial.lua")
local acoustics = import("goluwa/audio/acoustics.lua")
local ffi = require("ffi")
local fs = import("goluwa/filesystem/fs.lua")
local module = {}
local float_array_t = ffi.typeof("float[?]")
local int16_array_t = ffi.typeof("int16_t[?]")

local function u32(value)
	return string.char(
		value % 256,
		math.floor(value / 256) % 256,
		math.floor(value / 65536) % 256,
		math.floor(value / 16777216) % 256
	)
end

local function u16(value)
	return string.char(value % 256, math.floor(value / 256) % 256)
end

local function write_wav(path, samples, frames, sample_rate)
	local data = int16_array_t(frames * 2)

	for i = 0, frames * 2 - 1 do
		data[i] = math.floor(math.clamp(samples[i], -1, 1) * 32767)
	end

	local file = assert(io.open(path, "wb"))
	local bytes = frames * 4
	file:write(
		"RIFF",
		u32(36 + bytes),
		"WAVEfmt ",
		u32(16),
		u16(1),
		u16(2),
		u32(sample_rate),
		u32(sample_rate * 4),
		u16(4),
		u16(16),
		"data",
		u32(bytes),
		ffi.string(data, bytes)
	)
	file:close()
end

function module.Attach(audio)
	audio.clock = clock

	function audio.GetFreeSlot()
		for i = 0, audio.SLOT_COUNT - 1 do
			local slot = audio.state.slots[i]

			if not slot.active and not slot.draining then return i end
		end

		return nil
	end

	function audio.StealSlot(importance)
		local quietest, quietest_level

		for i = 0, audio.SLOT_COUNT - 1 do
			local slot = audio.state.slots[i]

			if slot.spatial and not slot.looping then
				local level = slot.volume * math.max(slot.ear_gain[1], slot.ear_gain[4])

				if level < importance and (not quietest or level < quietest_level) then
					quietest, quietest_level = i, level
				end
			end
		end

		if not quietest then return nil end

		local sound = audio.active_sounds[quietest]

		if sound then
			audio._clear_sound_slot(sound, false, true)
		else
			local slot = audio.state.slots[quietest]
			slot.active = false
			slot.paused = false
			slot.draining = false
			slot.start_serial = slot.start_serial + 1
		end

		return quietest
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

	function audio.SetAir(celsius, relative_humidity, pressure)
		audio.speed_of_sound = 331.3 * math.sqrt(1 + celsius / 273.15)
		audio.air_absorption_db = spatial_air.ComputeAirAbsorption(celsius, relative_humidity, pressure)
		spatial_air.AIR_SUBBANDS = spatial_air.ComputeAirSubbands(celsius, relative_humidity, pressure)
		spatial_air.SetAirConditions(celsius, relative_humidity, pressure)
		audio.state.air_scale = spatial_air.AIR_SCALE
		audio.state.air_flat_high = audio.air_absorption_db[3]

		for band = 1, 3 do
			spatial_air.AIR_ABSORPTION_DB[band] = audio.air_absorption_db[band]
		end
	end

	function audio.StartCapture(seconds)
		local state = audio.state
		local capacity = math.floor(seconds * state.sample_rate)
		audio.capture = {
			out = float_array_t(capacity * 2),
			dry = float_array_t(capacity * 2),
			rev = float_array_t(capacity * 2),
		}
		state.capture_out = audio.capture.out
		state.capture_dry = audio.capture.dry
		state.capture_rev = audio.capture.rev
		audio.capture.log = {}
		state.capture_frames = 0
		state.capture_capacity = capacity
	end

	function audio.LogCapture()
		local state = audio.state
		local at = state.capture_frames / state.sample_rate
		local log = audio.capture.log
		local position = audio.listener_position
		local lines = {
			string.format(
				"t=%.2f listener %.2f %.2f %.2f wind %.1f %.1f %.1f ear %.1f dB limiter %.1f dB",
				at,
				position.x,
				position.y,
				position.z,
				audio.wind.x,
				audio.wind.y,
				audio.wind.z,
				state.debug_ear_reduction,
				20 * math.log10(math.max(state.debug_limiter_gain, 1e-6))
			),
		}

		if not audio.capture.scene_logged then
			audio.capture.scene_logged = true
			local Entity = import("goluwa/entities/entity.lua")
			local near, models = {}, 0

			for _, entity in ipairs(Entity.World:GetChildrenList()) do
				if entity.model then
					models = models + 1

					if entity.transform and (entity.transform:GetPosition() - position):GetLength() < 4 then
						near[#near + 1] = string.format(
							"%s %.1f m",
							entity:GetName() ~= "" and entity:GetName() or tostring(entity),
							(entity.transform:GetPosition() - position):GetLength()
						)
					end
				end
			end

			lines[#lines + 1] = string.format(
				"  scene: %d entities with models, within 4 m of the listener: %s",
				models,
				#near > 0 and table.concat(near, ", ") or "none"
			)

			for _, entity in ipairs(Entity.World:GetChildrenList()) do
				if entity.model and entity.transform then
					local at = entity.transform:GetPosition()
					lines[#lines + 1] = string.format(
						"  model %s at %.0f %.0f %.0f scale %s path %s",
						entity:GetName() ~= "" and entity:GetName() or tostring(entity),
						at.x,
						at.y,
						at.z,
						tostring(entity.transform:GetScale()),
						tostring(entity.model.ModelPath)
					)
				end
			end
		end

		local environment = audio.acoustics

		if environment then
			local hits = environment.samples
			local floats = import("goluwa/audio/acoustics.lua").SAMPLE_FLOATS

			if hits and #hits > 0 then
				local distances, nearest = {}, {}

				for at = 0, #hits - 1, floats do
					local dx, dy, dz = hits[at + 1] - position.x, hits[at + 2] - position.y, hits[at + 3] - position.z
					distances[#distances + 1] = math.sqrt(dx * dx + dy * dy + dz * dz)
					nearest[#nearest + 1] = {distances[#distances], at}
				end

				table.sort(distances)

				table.sort(nearest, function(a, b)
					return a[1] < b[1]
				end)

				local parts = {}

				for i = 1, math.min(4, #nearest) do
					local at = nearest[i][2]
					parts[#parts + 1] = string.format(
						"%.1f m at %.0f %.0f %.0f n %.1f %.1f %.1f abs %.2f",
						nearest[i][1],
						hits[at + 1],
						hits[at + 2],
						hits[at + 3],
						hits[at + 4],
						hits[at + 5],
						hits[at + 6],
						hits[at + 10]
					)
				end

				lines[#lines + 1] = string.format(
					"  first hits: %d, distance 10%% %.1f 50%% %.1f 90%% %.1f m; nearest %s",
					#distances,
					distances[math.max(1, math.floor(#distances * 0.1))],
					distances[math.max(1, math.floor(#distances * 0.5))],
					distances[math.max(1, math.floor(#distances * 0.9))],
					table.concat(parts, " | ")
				)
			end

			local profile = environment.profile
			local ambient = environment.ambient_reverb
			lines[#lines + 1] = string.format(
				"  room: mfp %.1f m volume %.3g open %.2f profile predelay %.3f t60 %.2f/%.2f/%.2f ambient delay %.3f t60 %s rays %.0f",
				profile.mean_free_path,
				profile.volume,
				profile.openness,
				profile.predelay,
				profile.t60[1],
				profile.t60[2],
				profile.t60[3],
				ambient and ambient.delay or -1,
				ambient and
					string.format("%.2f/%.2f/%.2f", ambient.t60[1], ambient.t60[2], ambient.t60[3]) or
					"none",
				environment.stats.rays
			)
		end

		for b = 0, audio.BUS_COUNT - 1 do
			local bus = state.buses[b]
			lines[#lines + 1] = string.format(
				"  bus%d t60 %.2f %.2f %.2f predelay %.3f scale %.2f diffusion %.2f concentration %.2f rms %.1f dBFS",
				b,
				bus.t60[0],
				bus.t60[1],
				bus.t60[2],
				bus.predelay,
				bus.scale,
				bus.diffusion,
				bus.concentration,
				20 * math.log10(math.max(state.debug_bus_rms[b], 1e-9))
			)
		end

		for slot, sound in pairs(audio.active_sounds) do
			local st = state.slots[slot]

			if st.spatial and not st.looping then
				local p = sound:GetPosition()
				local env = sound.audio_environment
				local taps = {}

				for t = 0, audio.MAX_TAPS - 1 do
					local gain = math.max(st.tap_gain[t * 2], st.tap_gain[t * 2 + 1])

					if gain ~= 0 then
						taps[#taps + 1] = string.format(
							"%.3f@%.0fms%s",
							gain,
							st.tap_delay[t * 2] * 1000,
							st.ground_tap == t + 1 and "G" or ""
						)
					end
				end

				lines[#lines + 1] = string.format(
					"  sound %d energy %.3g (diffuse %.3g) emitter %s sums.rays %.0f at %.1f %.1f %.1f direct %.4f delay %.0f ms send %.4f/%.4f env.t60 %s trust %.2f playback %d/%d taps %s",
					slot,
					env and env.energy or -1,
					env and
						audio.acoustics and
						import("goluwa/audio/acoustics.lua").DiffuseEnergy(audio.acoustics.profile, (p - audio.listener_position):GetLength(), audio.speed_of_sound) or
						-1,
					env and tostring(env.emitter ~= nil) or "?",
					env and env.sums and env.sums.rays or -1,
					p.x,
					p.y,
					p.z,
					st.ear_gain[1],
					st.ear_delay[0] * 1000,
					st.send[0],
					st.send[1],
					env and
						env.t60 and
						string.format("%.1f/%.1f/%.1f", env.t60[1], env.t60[2], env.t60[3]) or
						"?",
					env and env.trust or -1,
					st.playback_pos,
					st.buffer_len,
					table.concat(taps, " ")
				)
			end
		end

		log[#log + 1] = table.concat(lines, "\n")
	end

	-- writes what the mixer thread rendered since StartCapture as stereo wavs: the output (after the ear and the limiter), the dry mix and the reverb buses (both after the master gain, before the ear)
	function audio.StopCapture(path_prefix)
		local state = audio.state
		local capture = audio.capture
		local frames = state.capture_frames
		state.capture_capacity = 0
		fs.create_directory_recursive(fs.get_parent_directory(path_prefix))

		for _, name in ipairs({"out", "dry", "rev"}) do
			write_wav(path_prefix .. "_" .. name .. ".wav", capture[name], frames, state.sample_rate)
		end

		local file = assert(io.open(path_prefix .. "_info.txt", "wb"))
		file:write(table.concat(capture.log, "\n"), "\n")
		file:close()
		audio.capture = nil
		return frames / state.sample_rate
	end

	function audio.SetAmbienceTracing(rain_up, upwind)
		audio.trace_ambience = true
		audio.rain_up = rain_up
		audio.upwind = upwind
	end

	function audio.SetWind(velocity)
		audio.wind = velocity
	end

	function audio.SetTurbulence(mean_square_index)
		audio.turbulence = mean_square_index
	end

	function audio.SetTemperatureGradient(kelvin_per_meter)
		audio.temperature_gradient = kelvin_per_meter
	end

	function audio.SetSnowDepth(meters)
		audio.snow_depth = meters
	end

	function audio.StopAmbienceTracing()
		audio.trace_ambience = false
	end

	function audio.SetListenerGain(gain)
		audio.state.master_volume = gain
	end

	function audio.GetListenerGain()
		return audio.state.master_volume
	end

	function audio.SPLToVolume(spl)
		return 10 ^ ((spl - audio.reference_spl) / 20)
	end

	function audio.VolumeToSPL(volume)
		return audio.reference_spl + 20 * math.log10(volume)
	end

	function audio.Update()
		local time = audio.clock()
		audio.UpdateListenerMotion(time)
		audio.UpdateCueGroups()
		local profile = audio.acoustics and audio.acoustics.profile
		-- indoors the air stands still: the wind reaches the paths as far as the listener's space is open
		local exposure = profile and math.clamp(profile.openness / acoustics.SPARSE_ESCAPING, 0, 1) or 1
		audio.medium_velocity = audio.wind * exposure

		-- the reflections are computed in acoustics:Update and must use this frame's tracked positions, like the direct path does after it
		for slot, sound in pairs(audio.active_sounds) do
			if audio.state.slots[slot].spatial then
				sound.audio_motion = spatial_air.UpdateMotion(sound.audio_motion or {}, sound:GetPosition(), time)
			end
		end

		if audio.acoustics then audio.acoustics:Update(time) end

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

				if sound.stream then audio.RefillStream(sound, state.playback_pos) end

				audio.UpdateSoundPaths(sound, time)
			end
		end
	end

	event.AddListener("Update", "audio_sync", audio.Update)
	local last_capture_log = 0

	event.AddListener("Update", "audio_capture_log", function()
		if audio.capture and audio.clock() - last_capture_log >= 0.1 then
			last_capture_log = audio.clock()
			audio.LogCapture()
		end
	end)

	return audio
end

return module
