local Vec3 = import("goluwa/structs/vec3.lua")
local dsp = import("goluwa/audio/dsp.lua")
local audio_state = import("goluwa/audio/state.lua")
local CUE_GROUPS = audio_state.CUE_GROUPS
local spatial = {}
spatial.MIN_RATE = -3
-- a supersonic source has two arrivals at once (or none) and a boom between them; one delay line follows it only below the speed of sound
spatial.MAX_SOURCE_MACH = 0.95
spatial.MAX_RATE = 0.75
spatial.PINNA_NOTCH = {frequency = 7500, octaves = 0.65, depth = 18, q = 2.5, rear = 0.6, far = 0.2}
spatial.PINNA_OVERHEAD = {frequency = 8000, gain = 10, q = 1.2}
spatial.PINNA_FRONT = {frequency = 4000, gain = 5, q = 0.8}
local VELOCITY_TIME_CONSTANT = 0.05
local TELEPORT_SPEED = 1000

function spatial.ComputeDistanceAttenuation(model, distance, reference_distance, max_distance, rolloff, ids)
	reference_distance = math.max(reference_distance, 0.0001)
	max_distance = math.max(max_distance, reference_distance)
	rolloff = math.max(rolloff, 0)

	if model == ids.none then return 1 end

	local d = math.max(distance, reference_distance)

	if
		model == ids.inverse_clamped or
		model == ids.linear_clamped or
		model == ids.exponent_clamped
	then
		d = math.clamp(d, reference_distance, max_distance)
	end

	if model == ids.inverse or model == ids.inverse_clamped then
		return reference_distance / (reference_distance + rolloff * (d - reference_distance))
	end

	if model == ids.linear or model == ids.linear_clamped then
		if max_distance <= reference_distance then return 1 end

		return math.clamp(
			1 - rolloff * (d - reference_distance) / (max_distance - reference_distance),
			0,
			1
		)
	end

	return (d / reference_distance) ^ -rolloff
end

function spatial.ComputeConeGain(direction, to_listener, inner_angle, outer_angle, outer_gain)
	if inner_angle >= 360 and outer_angle >= 360 then return 1 end

	if direction:IsZero() or to_listener:IsZero() then return 1 end

	local angle = math.deg(
		math.acos(math.clamp(direction:GetNormalized():GetDot(to_listener:GetNormalized()), -1, 1))
	)
	local inner_half = inner_angle * 0.5
	local outer_half = math.max(outer_angle, inner_angle) * 0.5

	if angle <= inner_half then return 1 end

	if angle >= outer_half or outer_half <= inner_half then return outer_gain end

	return 1 + (outer_gain - 1) * (angle - inner_half) / (outer_half - inner_half)
end

do
	local T0 = 293.15
	local T01 = 273.16
	local REFERENCE_PRESSURE = 101325
	-- band coefficients are fitted at this distance: the energy average over a band does not fall exponentially
	local FIT_DISTANCE = 30
	local SUBBANDS = 6
	local EDGES = {{50, 500}, {500, 4000}, {4000, 16000}}

	function spatial.AirAbsorptionAt(frequency, celsius, relative_humidity, pressure)
		local t = celsius + 273.15
		local pa = pressure / REFERENCE_PRESSURE
		local saturation = 10 ^ (-6.8346 * (T01 / t) ^ 1.261 + 4.6151)
		local h = relative_humidity * 100 * saturation / pa
		local fr_o = pa * (24 + 4.04e4 * h * (0.02 + h) / (0.391 + h))
		local fr_n = pa * (
				t / T0
			) ^ -0.5 * (
				9 + 280 * h * math.exp(-4.170 * ((t / T0) ^ (-1 / 3) - 1))
			)
		local f2 = frequency * frequency
		return 8.686 * f2 * (
				1.84e-11 / pa * (
					t / T0
				) ^ 0.5 + (
					t / T0
				) ^ -2.5 * (
					0.01275 * math.exp(-2239.1 / t) / (
						fr_o + f2 / fr_o
					) + 0.1068 * math.exp(-3352 / t) / (
						fr_n + f2 / fr_n
					)
				)
			)
	end

	-- per band the absorption of its sub frequencies, so a band's loss can be summed at any distance
	function spatial.ComputeAirSubbands(celsius, relative_humidity, pressure)
		local out = {}

		for band = 1, 3 do
			local low, high = EDGES[band][1], EDGES[band][2]
			out[band] = {}

			for k = 1, SUBBANDS do
				out[band][k] = spatial.AirAbsorptionAt(low * (high / low) ^ ((k - 0.5) / SUBBANDS), celsius, relative_humidity, pressure)
			end
		end

		return out
	end

	function spatial.ComputeAirAbsorption(celsius, relative_humidity, pressure)
		local out = {}

		for band = 1, 3 do
			local low, high = EDGES[band][1], EDGES[band][2]
			local energy = 0

			for k = 1, SUBBANDS do
				local frequency = low * (high / low) ^ ((k - 0.5) / SUBBANDS)
				energy = energy + 10 ^ (
						-spatial.AirAbsorptionAt(frequency, celsius, relative_humidity, pressure) * FIT_DISTANCE / 10
					) / SUBBANDS
			end

			out[band] = -10 * math.log10(energy) / FIT_DISTANCE
		end

		return out
	end
end

spatial.AIR_ABSORPTION_DB = spatial.ComputeAirAbsorption(20, 0.5, 101325)
spatial.AIR_SUBBANDS = spatial.ComputeAirSubbands(20, 0.5, 101325)

-- the band's energy is the mean of its sub frequencies, each decaying on its own: far away only the low end of a band is left
function spatial.AirAbsorption(band, distance)
	local subbands = spatial.AIR_SUBBANDS[band]
	local energy = 0

	for k = 1, #subbands do
		energy = energy + 10 ^ (-subbands[k] * distance / 10)
	end

	return math.sqrt(energy / #subbands)
end

function spatial.HeadShadow(band, side, front)
	local shadow = math.max(0, -side)
	local back = math.max(0, -front)

	if band == 1 then return 1 - 0.15 * shadow end

	if band == 2 then return (1 - 0.45 * shadow) * (1 - 0.1 * back) end

	return (1 - 0.7 * shadow) * (1 - 0.3 * back)
end

function spatial.GetPinnaCues(height, front, toward, strength)
	local notch = spatial.PINNA_NOTCH
	return notch.frequency * 2 ^ (notch.octaves * height),
	-notch.depth * (
			1 - math.max(height, 0)
		) * (
			1 - (
				1 - notch.rear
			) * math.max(-front, 0)
		) * (
			notch.far + (
				1 - notch.far
			) * (
				0.5 + 0.5 * toward
			)
		) * strength,
	spatial.PINNA_OVERHEAD.gain * math.max(height, 0) * strength,
	spatial.PINNA_FRONT.gain * front * strength
end

function spatial.WriteCueGroups(state, strength)
	for group = 0, CUE_GROUPS - 1 do
		local height = (math.floor(group / 2) - 1) * audio_state.CUE_GROUP_HEIGHT
		local front = (group % 2 == 0 and 1 or -1) * math.sqrt(1 - height * height)
		local notch_frequency, notch_gain, overhead_gain, front_gain = spatial.GetPinnaCues(height, front, 0, strength)
		local at = group * 3
		state.cue_frequency[at], state.cue_gain[at] = notch_frequency, notch_gain
		state.cue_frequency[at + 1], state.cue_gain[at + 1] = spatial.PINNA_OVERHEAD.frequency, overhead_gain
		state.cue_frequency[at + 2], state.cue_gain[at + 2] = spatial.PINNA_FRONT.frequency, front_gain
	end

	state.cue_q[0] = spatial.PINNA_NOTCH.q
	state.cue_q[1] = spatial.PINNA_OVERHEAD.q
	state.cue_q[2] = spatial.PINNA_FRONT.q
end

-- solves |ear - source + v delay| = speed delay: the sound now arriving left where the source was a delay ago; v is the source velocity relative to the air
function spatial.RetardedDelay(ear, source, source_velocity, speed)
	local rx, ry, rz = ear.x - source.x, ear.y - source.y, ear.z - source.z
	local vx, vy, vz = source_velocity.x, source_velocity.y, source_velocity.z
	local v2 = vx * vx + vy * vy + vz * vz
	local max_speed = speed * spatial.MAX_SOURCE_MACH

	if v2 > max_speed * max_speed then
		local k = max_speed / math.sqrt(v2)
		vx, vy, vz, v2 = vx * k, vy * k, vz * k, max_speed * max_speed
	end

	local rv = rx * vx + ry * vy + rz * vz
	local r2 = rx * rx + ry * ry + rz * rz
	local a = speed * speed - v2
	return (rv + math.sqrt(rv * rv + a * r2)) / a
end

function spatial.DelayRate(from, to, from_velocity, to_velocity, speed)
	local direction = to - from

	if direction:IsZero() then return 0 end

	direction = direction:GetNormalized()
	local source_radial = direction:GetDot(from_velocity)
	local rate = (
			direction:GetDot(to_velocity) - source_radial
		) / math.max(speed - source_radial, 0.0001)
	return math.clamp(rate, spatial.MIN_RATE, spatial.MAX_RATE)
end

function spatial.UpdateMotion(motion, position, time)
	if not motion.time then
		motion.time = time
		motion.position = position:Copy()
		motion.velocity = Vec3(0, 0, 0)
		return motion
	end

	local dt = time - motion.time

	if dt <= 0 then return motion end

	local step = position - motion.position
	local speed = step:GetLength() / dt

	if speed > TELEPORT_SPEED then
		motion.velocity = Vec3(0, 0, 0)
	else
		motion.velocity = motion.velocity + (
				step / dt - motion.velocity
			) * (
				1 - math.exp(-dt / VELOCITY_TIME_CONSTANT)
			)
	end

	motion.position = position:Copy()
	motion.time = time
	return motion
end

function spatial.ComputePaths(audio, sound, out)
	out = out or
		{
			ear_delay = {},
			ear_rate = {},
			ear_gain = {},
			ear_filter_frequency = {},
			ear_filter_gain = {},
		}
	local listener = audio.listener_position
	local forward = audio.listener_forward:GetNormalized()
	local right = forward:GetCross(audio.listener_up)

	if right:IsZero() then
		right = Vec3(1, 0, 0)
	else
		right = right:GetNormalized()
	end

	local source = sound:GetPosition()
	local motion = sound.audio_motion
	local source_velocity = motion and motion.velocity or Vec3(0, 0, 0)
	local listener_velocity = audio.listener_motion.velocity or Vec3(0, 0, 0)
	local doppler = audio.doppler_factor
	local speed = audio.speed_of_sound / math.max(doppler, 0.000001)
	local to_source = source - listener
	local distance = to_source:GetLength()
	local direction = distance > 0.0001 and to_source / distance or forward
	local side = direction:GetDot(right)
	local front = direction:GetDot(forward)
	local height = direction:GetDot(right:GetCross(forward))
	local pinna = audio.pinna_cues:Get()
	local attenuation = spatial.ComputeDistanceAttenuation(
		audio.DISTANCE_MODE_IDS[audio.distance_model],
		distance,
		sound:GetReferenceDistance(),
		sound:GetMaxDistance(),
		sound:GetRolloffFactor(),
		audio.DISTANCE_MODE_IDS
	)
	local cone = spatial.ComputeConeGain(
		sound:GetDirection(),
		-to_source,
		sound:GetInnerConeAngle(),
		sound:GetOuterConeAngle(),
		sound:GetOuterConeGain()
	)
	local occlusion = sound.audio_occlusion
	local tone = sound:GetBandGains()
	local half_ear = right * (audio.ear_distance * 0.5)

	for ear = 1, 2 do
		local sign = ear == 1 and -1 or 1
		local ear_position = listener + half_ear * sign

		if doppler <= 0 then
			out.ear_delay[ear] = 0
			out.ear_rate[ear] = 0
		else
			local delay = spatial.RetardedDelay(ear_position, source, source_velocity, speed)
			out.ear_delay[ear] = delay
			out.ear_rate[ear] = spatial.DelayRate(
				source - source_velocity * delay,
				ear_position,
				source_velocity,
				listener_velocity,
				speed
			)
		end

		for band = 1, 3 do
			out.ear_gain[(ear - 1) * 3 + band] = attenuation * cone * spatial.AirAbsorption(band, distance) * spatial.HeadShadow(band, side * sign, front) * (
					occlusion and
					occlusion[band] or
					1
				) * (
					band == 1 and
					tone.x or
					band == 2 and
					tone.y or
					tone.z
				)
		end

		local f = (ear - 1) * 3
		local notch_frequency, notch_gain, overhead_gain, front_gain = spatial.GetPinnaCues(height, front, side * sign, pinna)
		out.ear_filter_frequency[f + 1] = notch_frequency
		out.ear_filter_gain[f + 1] = notch_gain
		out.ear_filter_frequency[f + 2] = spatial.PINNA_OVERHEAD.frequency
		out.ear_filter_gain[f + 2] = overhead_gain
		out.ear_filter_frequency[f + 3] = spatial.PINNA_FRONT.frequency
		out.ear_filter_gain[f + 3] = front_gain
	end

	out.distance = distance
	out.attenuation = attenuation
	out.cone_gain = cone
	out.direction = direction
	out.side = side
	out.front = front
	return out
end

function spatial.WriteSlot(slot, paths, sound, time)
	for ear = 0, 1 do
		slot.ear_delay[ear] = paths.ear_delay[ear + 1]
		slot.ear_rate[ear] = paths.ear_rate[ear + 1]
	end

	for ear = 0, 1 do
		local g = paths.ear_gain
		slot.ear_gain[ear * 3], slot.ear_gain[ear * 3 + 1], slot.ear_gain[ear * 3 + 2] = dsp.WarpBandGains(g[ear * 3 + 1], g[ear * 3 + 2], g[ear * 3 + 3])
	end

	for i = 0, 5 do
		slot.ear_filter_frequency[i] = paths.ear_filter_frequency[i + 1]
		slot.ear_filter_gain[i] = paths.ear_filter_gain[i + 1]
	end

	slot.ear_filter_q[0] = spatial.PINNA_NOTCH.q
	slot.ear_filter_q[1] = spatial.PINNA_OVERHEAD.q
	slot.ear_filter_q[2] = spatial.PINNA_FRONT.q
	local env = sound.audio_environment

	for t = 0, 7 do
		local tap = env and env.taps[t + 1]

		if tap then
			slot.tap_delay[t * 2] = tap.delay_left
			slot.tap_delay[t * 2 + 1] = tap.delay_right
			slot.tap_rate[t * 2] = tap.rate_left
			slot.tap_rate[t * 2 + 1] = tap.rate_right
			slot.tap_height[t] = tap.height
			slot.tap_front[t] = tap.front
			slot.tap_gain[t * 2] = tap.gain_left
			slot.tap_gain[t * 2 + 1] = tap.gain_right
		else
			slot.tap_gain[t * 2] = 0
			slot.tap_gain[t * 2 + 1] = 0
		end
	end

	local tone = sound:GetBandGains()

	if env then
		slot.tap_band[0], slot.tap_band[1], slot.tap_band[2] = dsp.WarpBandGains(env.tap_band[1] * tone.x, env.tap_band[2] * tone.y, env.tap_band[3] * tone.z)
	else
		slot.tap_band[0], slot.tap_band[1], slot.tap_band[2] = dsp.WarpBandGains(tone.x, tone.y, tone.z)
	end

	for bus = 0, 1 do
		slot.send[bus] = env and env.send[bus + 1] or 0
	end

	slot.param_time = time
	slot.param_serial = slot.param_serial + 1
end

function spatial.Attach(audio)
	audio.listener_motion = {}
	local paths = {
		ear_delay = {},
		ear_rate = {},
		ear_gain = {},
		ear_filter_frequency = {},
		ear_filter_gain = {},
	}

	function audio.UpdateSoundPaths(sound, time)
		local slot = audio.state.slots[sound.slot]

		if not slot.spatial then return end

		sound.audio_motion = spatial.UpdateMotion(sound.audio_motion or {}, sound:GetPosition(), time)
		spatial.WriteSlot(slot, spatial.ComputePaths(audio, sound, paths), sound, time)
	end

	function audio.ComputePaths(sound)
		return spatial.ComputePaths(audio, sound)
	end

	function audio.UpdateListenerMotion(time)
		spatial.UpdateMotion(audio.listener_motion, audio.listener_position, time)
	end

	function audio.UpdateCueGroups()
		spatial.WriteCueGroups(audio.state, audio.pinna_cues:Get())
	end

	return audio
end

return spatial
