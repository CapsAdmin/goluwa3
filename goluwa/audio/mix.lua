local ffi = require("ffi")
local bit = require("bit")
local dsp = import("goluwa/audio/dsp.lua")
local spatial = import("goluwa/audio/spatial.lua")
local ground = import("goluwa/audio/ground.lua")
local clock = import("goluwa/audio/clock.lua")
local audio_state = import("goluwa/audio/state.lua")
local mix = {}
mix.MIN_HISTORY_SIZE = 131072
mix.REVERB_SPEED_OF_SOUND = 343.3
mix.MAX_REVERB_T60 = 12
local HISTORY_GUARD = 8192
local SLOT_COUNT = audio_state.SLOT_COUNT
local MAX_TAPS = audio_state.MAX_TAPS
local BUS_COUNT = audio_state.BUS_COUNT
local CUE_GROUPS = audio_state.CUE_GROUPS
local CUE_GROUP_HEIGHT = audio_state.CUE_GROUP_HEIGHT
local CUE_TAIL_BLOCKS = 8
local MIN_DELAY = 2
local DECLICK = 0.003
local SLOPE_RESPONSE = 0.5
-- the read speed is the reported delay rate, and the delay error left over is corrected over this long: noise in the targets would otherwise land on the pitch within a block
local DELAY_CORRECTION = 0.1
local MIN_SLOPE = -3
local MAX_SLOPE = 0.75
local voice_t = ffi.typeof(
	[[
	struct {
		float *history;
		float *tap_history;
		float *side_history;
		float *ground_history;
		bool ground_active;
		double written;
		double last_signal;
		double volume;
		uint32_t history_size;
		double ear_delay[2];
		double ear_slope[2];
		double ear_gain[6];
		double ear_state[8];
		double ear_filter_frequency[6];
		double ear_filter_gain[6];
		double ear_filter_state[12];
		double air_state[12];
		double scintillation_state[2];
		int32_t scintillation_seed;
		double air_coefficient[12];
		double send_air_state[6];
		double send_air_coefficient[6];
		double tap_delay[$];
		double tap_gain[$];
		double tap_group[$];
		double tap_band[3];
		double tap_state[4];
		double send[$];
		double tap_air_state[$];
		double tap_air_coefficient[$];
		uint32_t start_serial;
		bool initialized;
		bool emitting;
		bool idle;
	}
]],
	MAX_TAPS * 2,
	MAX_TAPS * 2,
	MAX_TAPS * CUE_GROUPS,
	BUS_COUNT,
	MAX_TAPS * 12,
	MAX_TAPS * 6
)
local scratch_t = ffi.typeof("double[?]")

function mix.CreateMixer(state, sample_rate, max_frames)
	max_frames = max_frames or 4096
	local mixer = {
		state = state,
		sample_rate = sample_rate,
		max_frames = max_frames,
		voices = ffi.new(ffi.typeof("$[$]", voice_t, SLOT_COUNT)),
		histories = {},
		tap_histories = {},
		side_histories = {},
		side_dummy = ffi.new("float[1]"),
		ground_histories = {},
		convolvers = {},
		cue_left = {},
		cue_right = {},
		cue_state = ffi.new("double[?]", CUE_GROUPS * 12),
		cue_coefficients = ffi.new("double[?]", CUE_GROUPS * 12),
		cue_used = false,
		cue_tail = 0,
		buses = {},
		bus_input = {},
		send_scratch = scratch_t(max_frames),
		bus_before = ffi.new("float[?]", max_frames * 2),
		scintillation_mid = scratch_t(max_frames),
		scintillation_high = scratch_t(max_frames),
		tap_left = scratch_t(max_frames),
		tap_right = scratch_t(max_frames),
		coefficient_low = dsp.OnePoleCoefficient(dsp.LOW_CROSSOVER, sample_rate),
		coefficient_high = dsp.OnePoleCoefficient(dsp.HIGH_CROSSOVER, sample_rate),
		frames_done = 0,
		ear = dsp.CreateEar(sample_rate),
		limiter = dsp.CreateLimiter(sample_rate),
		clock = clock,
	}
	state.sample_rate = sample_rate

	for i = 0, SLOT_COUNT - 1 do
		mixer.voices[i].idle = true
	end

	for b = 0, BUS_COUNT - 1 do
		mixer.buses[b] = dsp.CreateReverb(sample_rate)
		mixer.bus_input[b] = ffi.new("float[?]", max_frames)
	end

	for g = 0, CUE_GROUPS - 1 do
		mixer.cue_left[g] = scratch_t(max_frames)
		mixer.cue_right[g] = scratch_t(max_frames)
	end

	return mixer
end

local function history_size(mixer, slot)
	local needed = math.ceil(slot.history_seconds * mixer.sample_rate) + HISTORY_GUARD + mixer.max_frames
	local size = mix.MIN_HISTORY_SIZE

	while size < needed do
		size = size * 2
	end

	return size
end

local function allocate_history(mixer, index, voice, slot, size, keep)
	local old_size = voice.history_size
	local history = ffi.new("float[?]", size)
	local tap_history = ffi.new("float[?]", size)
	local side_history = slot.channels == 2 and ffi.new("float[?]", size) or mixer.side_dummy

	if keep then
		local mask, old_mask = size - 1, old_size - 1

		for w = math.max(voice.written - old_size, 0), voice.written - 1 do
			history[bit.band(w, mask)] = voice.history[bit.band(w, old_mask)]
			tap_history[bit.band(w, mask)] = voice.tap_history[bit.band(w, old_mask)]

			if slot.channels == 2 then
				side_history[bit.band(w, mask)] = voice.side_history[bit.band(w, old_mask)]
			end
		end
	end

	if voice.ground_history ~= nil and voice.ground_active then
		local ground_history = ffi.new("float[?]", size)

		if keep then
			for w = math.max(voice.written - old_size, 0), voice.written - 1 do
				ground_history[bit.band(w, size - 1)] = voice.ground_history[bit.band(w, old_size - 1)]
			end
		end

		mixer.ground_histories[index] = ground_history
		voice.ground_history = ground_history
	else
		mixer.ground_histories[index] = nil
		voice.ground_history = nil
		voice.ground_active = false
	end

	mixer.histories[index] = history
	mixer.tap_histories[index] = tap_history
	mixer.side_histories[index] = side_history
	voice.history = history
	voice.tap_history = tap_history
	voice.side_history = side_history
	voice.history_size = size
end

local function update_ground(mixer, index, voice, slot, frames)
	if slot.ground_tap == 0 then
		voice.ground_active = false
		return
	end

	if not voice.ground_active then
		local ground_history = ffi.new("float[?]", voice.history_size)
		mixer.ground_histories[index] = ground_history
		voice.ground_history = ground_history
		voice.ground_active = true
		mixer.convolvers[index] = mixer.convolvers[index] or ground.CreateConvolver()
		mixer.convolvers[index].serial = -1
	end

	local convolver = mixer.convolvers[index]

	if convolver.serial ~= slot.ground_serial then
		ground.SetFilter(convolver, slot.ground_ir)
		convolver.serial = slot.ground_serial
	end

	local mask = voice.history_size - 1
	local start = voice.written - frames
	local done = 0

	while done < frames do
		local count = math.min(frames - done, ground.FFT_SIZE - ground.IR_SIZE + 1)
		ground.Convolve(convolver, voice.history, mask, voice.ground_history, mask, start + done, count)
		done = done + count
	end
end

local function reset_voice(mixer, index, voice, slot)
	if slot.spatial then
		local size = history_size(mixer, slot)
		local stereo_changed = (voice.side_history ~= mixer.side_dummy) ~= (slot.channels == 2)

		if
			voice.history == nil or
			stereo_changed or
			voice.history_size < size or
			voice.history_size > size * 4
		then
			allocate_history(mixer, index, voice, slot, size, false)
		else
			ffi.fill(voice.history, voice.history_size * 4)
			ffi.fill(voice.tap_history, voice.history_size * 4)

			if slot.channels == 2 then
				ffi.fill(voice.side_history, voice.history_size * 4)
			end
		end
	end

	voice.scintillation_state[0], voice.scintillation_state[1] = 0, 0
	voice.scintillation_seed = (index + 1) * 2654435 + 1
	voice.ground_active = false
	voice.written = 0
	voice.last_signal = 0
	voice.volume = slot.volume
	voice.initialized = false
	voice.emitting = true
	voice.idle = false
	voice.start_serial = slot.start_serial

	for i = 0, 7 do
		voice.ear_state[i] = 0
	end

	for i = 0, 3 do
		voice.tap_state[i] = 0
	end

	for i = 0, 2 do
		voice.tap_band[i] = slot.tap_band[i]
	end

	for i = 0, MAX_TAPS * CUE_GROUPS - 1 do
		voice.tap_group[i] = 0
	end

	for i = 0, 11 do
		voice.ear_filter_state[i] = 0
		voice.air_state[i] = 0
	end

	for i = 0, 5 do
		voice.send_air_state[i] = 0
	end

	for i = 0, MAX_TAPS * 2 - 1 do
		voice.tap_gain[i] = 0
	end

	for i = 0, MAX_TAPS * 12 - 1 do
		voice.tap_air_state[i] = 0
	end

	for i = 0, MAX_TAPS * 6 - 1 do
		voice.tap_air_coefficient[i] = 1
	end

	for i = 0, MAX_TAPS * 2 - 1 do
		voice.tap_delay[i] = 0
	end

	for b = 0, BUS_COUNT - 1 do
		voice.send[b] = 0
	end
end

local function read_source(samples, channels, length, index, looping)
	if index >= length then
		if not looping then return 0, 0 end

		index = index % length
	end

	if channels == 2 then
		local l, r = samples[index * 2], samples[index * 2 + 1]
		return (l + r) * 0.5, (l - r) * 0.5
	end

	return samples[index], 0
end

local function emit(mixer, slot, voice, frames, sample_rate)
	local history = voice.history
	local tap_history = voice.tap_history
	local side_history = voice.side_history
	local stereo = slot.channels == 2
	local mask = voice.history_size - 1
	local written = voice.written
	local volume = voice.volume
	local target_volume = slot.volume
	local volume_step = (target_volume - volume) / frames
	voice.volume = target_volume

	if not voice.emitting or slot.paused or not slot.active then
		for i = 0, frames - 1 do
			local at = bit.band(written + i, mask)
			history[at] = 0
			tap_history[at] = 0

			if stereo then side_history[at] = 0 end
		end

		for i = 0, 3 do
			voice.tap_state[i] = 0
		end

		voice.written = written + frames
		return
	end

	local ca = mixer.coefficient_low
	local cb = mixer.coefficient_high
	local states = voice.tap_state
	local la, lb, ha, hb = states[0], states[1], states[2], states[3]
	local gl, gm, gh = voice.tap_band[0], voice.tap_band[1], voice.tap_band[2]
	local tl, tm, th = slot.tap_band[0], slot.tap_band[1], slot.tap_band[2]
	local dl, dm, dh = (tl - gl) / frames, (tm - gm) / frames, (th - gh) / frames
	local samples = ffi.cast("float*", slot.buffer)
	local channels = slot.channels
	local length = slot.buffer_len
	local looping = slot.looping
	local rate = slot.pitch * slot.sample_rate / sample_rate
	local position = slot.playback_pos
	local played = slot.played
	local inv_in = 1 / (math.max(slot.fade_in, DECLICK) * slot.sample_rate)
	local inv_out = 1 / (math.max(slot.fade_out, DECLICK) * slot.sample_rate)

	if rate < 0 then rate = 0 end

	for i = 0, frames - 1 do
		local index = math.floor(position)

		if index >= length then
			if looping and length > 0 then
				position = position - length
				index = math.floor(position)
			else
				voice.emitting = false
				slot.active = false
				slot.draining = true

				for j = i, frames - 1 do
					local at = bit.band(written + j, mask)
					history[at] = 0
					tap_history[at] = 0

					if stereo then side_history[at] = 0 end
				end

				break
			end
		end

		local a, sa = read_source(samples, channels, length, index, looping)
		local b, sb = read_source(samples, channels, length, index + 1, looping)
		volume = volume + volume_step
		local envelope = played * inv_in

		if envelope > 1 then envelope = 1 end

		if not looping then
			local fade_out = (length - position) * inv_out

			if fade_out < envelope then envelope = fade_out end
		end

		played = played + rate
		local gain = volume * envelope
		local f = position - index
		local x = (a + (b - a) * f) * gain
		local at = bit.band(written + i, mask)
		history[at] = x

		if stereo then side_history[at] = (sa + (sb - sa) * f) * gain end

		la = la + ca * (x - la)
		lb = lb + ca * (la - lb)
		ha = ha + cb * (x - ha)
		hb = hb + cb * (ha - hb)
		gl = gl + dl
		gm = gm + dm
		gh = gh + dh
		tap_history[at] = gh * x + (gm - gh) * hb + (gl - gm) * lb
		position = position + rate
	end

	states[0], states[1], states[2], states[3] = la, lb, ha, hb
	voice.tap_band[0], voice.tap_band[1], voice.tap_band[2] = tl, tm, th
	slot.playback_pos = position
	slot.played = played
	voice.last_signal = written + frames
	voice.written = written + frames
end

local function track_delay(current, slope, target, rate, frames, initialized, snap, correction)
	if not initialized or math.abs(target - current) > snap then
		return target, 0
	end

	local wanted = rate + (target - current - rate * frames) / math.max(correction, frames)
	slope = slope + (wanted - slope) * SLOPE_RESPONSE
	return current, math.clamp(slope, MIN_SLOPE, MAX_SLOPE)
end

local function clamp_delay(samples, voice)
	return math.clamp(samples, MIN_DELAY, voice.history_size - HISTORY_GUARD)
end

local FILTER_STEP = 32
local filter_coefficients = ffi.new("double[12]")

local function render_ear(mixer, slot, voice, ear, base, delay, slope, out, frames, scintillating)
	local scintillation_mid, scintillation_high = mixer.scintillation_mid, mixer.scintillation_high
	local history = voice.history
	local mask = voice.history_size - 1
	local side_history = voice.side_history
	local stereo = slot.channels == 2
	local side_sign = ear == 0 and 1 or -1
	local ca = mixer.coefficient_low
	local cb = mixer.coefficient_high
	local states = voice.ear_state
	local si = ear * 4
	local la, lb, ha, hb = states[si], states[si + 1], states[si + 2], states[si + 3]
	local gi = ear * 3
	local gl, gm, gh = voice.ear_gain[gi], voice.ear_gain[gi + 1], voice.ear_gain[gi + 2]
	local tl, tm, th = slot.ear_gain[gi], slot.ear_gain[gi + 1], slot.ear_gain[gi + 2]
	local dl, dm, dh = (tl - gl) / frames, (tm - gm) / frames, (th - gh) / frames
	local frequency, gain = voice.ear_filter_frequency, voice.ear_filter_gain
	local target_frequency, target_gain = slot.ear_filter_frequency, slot.ear_filter_gain
	local filtered = false
	local changing = false

	for k = gi, gi + 2 do
		if gain[k] ~= 0 or target_gain[k] ~= 0 then filtered = true end

		if gain[k] ~= target_gain[k] or frequency[k] ~= target_frequency[k] then
			changing = true
		end
	end

	local fs = voice.ear_filter_state
	local fi = ear * 6
	local s1a, s2a, s1b, s2b, s1c, s2c = fs[fi], fs[fi + 1], fs[fi + 2], fs[fi + 3], fs[fi + 4], fs[fi + 5]
	local c = filter_coefficients
	local air = voice.air_state
	local ai = ear * 6
	local p1, p2, p3, p4, p5, p6 = air[ai], air[ai + 1], air[ai + 2], air[ai + 3], air[ai + 4], air[ai + 5]
	local air_now, air_target = voice.air_coefficient, slot.ear_air
	local c1, c2, c3, c4, c5, c6 = air_now[ai],
	air_now[ai + 1],
	air_now[ai + 2],
	air_now[ai + 3],
	air_now[ai + 4],
	air_now[ai + 5]
	local d1, d2, d3, d4, d5, d6 = (air_target[ai] - c1) / frames,
	(air_target[ai + 1] - c2) / frames,
	(air_target[ai + 2] - c3) / frames,
	(air_target[ai + 3] - c4) / frames,
	(air_target[ai + 4] - c5) / frames,
	(air_target[ai + 5] - c6) / frames
	local from = 0

	while from < frames do
		local to = changing and math.min(from + FILTER_STEP, frames) or frames

		if filtered then
			local t = to / frames

			for k = 0, 2 do
				local f = frequency[gi + k]
				dsp.PeakingCoefficients(
					c,
					k * 4,
					f * (target_frequency[gi + k] / f) ^ t,
					gain[gi + k] + (target_gain[gi + k] - gain[gi + k]) * t,
					slot.ear_filter_q[k],
					mixer.sample_rate
				)
			end
		end

		for i = from, to - 1 do
			local read = base + i - (delay + slope * (i + 1))
			local x = dsp.ReadCubic(history, mask, read)

			if stereo then
				x = x + side_sign * dsp.ReadCubic(side_history, mask, read)
			end

			la = la + ca * (x - la)
			lb = lb + ca * (la - lb)
			ha = ha + cb * (x - ha)
			hb = hb + cb * (ha - hb)
			gl = gl + dl
			gm = gm + dm
			gh = gh + dh
			local ym, yh = gm, gh

			if scintillating then
				ym = gm * scintillation_mid[i]
				yh = gh * scintillation_high[i]
			end

			local y = yh * x + (ym - yh) * hb + (gl - ym) * lb

			if filtered then
				local z = c[0] * y + s1a
				s1a = c[1] * (y - z) + s2a
				s2a = c[2] * y - c[3] * z
				y = c[4] * z + s1b
				s1b = c[5] * (z - y) + s2b
				s2b = c[6] * z - c[7] * y
				z = c[8] * y + s1c
				s1c = c[9] * (y - z) + s2c
				s2c = c[10] * y - c[11] * z
				y = z
			end

			c1, c2, c3, c4, c5, c6 = c1 + d1, c2 + d2, c3 + d3, c4 + d4, c5 + d5, c6 + d6
			local v = (y - p1) * c1
			y = p1 + v
			p1 = y + v
			v = (y - p2) * c2
			y = p2 + v
			p2 = y + v
			v = (y - p3) * c3
			y = p3 + v
			p3 = y + v
			v = (y - p4) * c4
			y = p4 + v
			p4 = y + v
			v = (y - p5) * c5
			y = p5 + v
			p5 = y + v
			v = (y - p6) * c6
			y = p6 + v
			p6 = y + v
			local index = i * 2 + ear
			out[index] = out[index] + y
		end

		from = to
	end

	if not filtered then s1a, s2a, s1b, s2b, s1c, s2c = 0, 0, 0, 0, 0, 0 end

	fs[fi], fs[fi + 1], fs[fi + 2], fs[fi + 3], fs[fi + 4], fs[fi + 5] = s1a, s2a, s1b, s2b, s1c, s2c
	air[ai], air[ai + 1], air[ai + 2], air[ai + 3], air[ai + 4], air[ai + 5] = p1, p2, p3, p4, p5, p6

	for k = ai, ai + 5 do
		air_now[k] = air_target[k]
	end

	states[si], states[si + 1], states[si + 2], states[si + 3] = la, lb, ha, hb
	voice.ear_gain[gi], voice.ear_gain[gi + 1], voice.ear_gain[gi + 2] = tl, tm, th

	for k = gi, gi + 2 do
		frequency[k] = target_frequency[k]
		gain[k] = target_gain[k]
	end
end

local group_weights = ffi.new("double[?]", CUE_GROUPS)

local function set_group_weights(height, front)
	for g = 0, CUE_GROUPS - 1 do
		group_weights[g] = 0
	end

	local across = math.sqrt(math.max(1 - height * height, 0))
	local ahead = across > 0.001 and math.clamp(front / across, -1, 1) or 0
	local level = math.clamp(height / CUE_GROUP_HEIGHT, -1, 1)
	local row = level >= 0 and 2 or 0
	local blend = math.abs(level)
	local w_front, w_back = 0.5 + 0.5 * ahead, 0.5 - 0.5 * ahead
	group_weights[2] = (1 - blend) * w_front
	group_weights[3] = (1 - blend) * w_back
	group_weights[row * 2] = group_weights[row * 2] + blend * w_front
	group_weights[row * 2 + 1] = group_weights[row * 2 + 1] + blend * w_back
end

local function air_cascade(state, at, coefficient, ct, x)
	for k = 0, 5 do
		local s = state[at + k]
		local v = (x - s) * coefficient[ct + k]
		x = s + v
		state[at + k] = x + v
	end

	return x
end

local function render_taps(mixer, slot, voice, base, frames, elapsed)
	local tap_history = voice.tap_history
	local mask = voice.history_size - 1
	local sample_rate = mixer.sample_rate
	local tap_left = mixer.tap_left
	local tap_right = mixer.tap_right
	local any = false

	for t = 0, MAX_TAPS - 1 do
		local on_ground = slot.ground_tap == t + 1 and voice.ground_active
		local source_history = on_ground and voice.ground_history or tap_history
		local ahead = on_ground and slot.ground_ahead or 0
		local gain_left = voice.tap_gain[t * 2]
		local gain_right = voice.tap_gain[t * 2 + 1]
		local target_left = slot.tap_gain[t * 2]
		local target_right = slot.tap_gain[t * 2 + 1]

		if gain_left ~= 0 or gain_right ~= 0 or target_left ~= 0 or target_right ~= 0 then
			local target_delay_left = clamp_delay((slot.tap_delay[t * 2] + slot.tap_rate[t * 2] * elapsed) * sample_rate - ahead, voice)
			local target_delay_right = clamp_delay((slot.tap_delay[t * 2 + 1] + slot.tap_rate[t * 2 + 1] * elapsed) * sample_rate - ahead, voice)
			local delay_left = voice.tap_delay[t * 2]
			local delay_right = voice.tap_delay[t * 2 + 1]
			local silent = math.abs(gain_left) + math.abs(gain_right) < 1e-6

			if not voice.initialized then
				gain_left, gain_right = target_left, target_right
			end

			if silent or not voice.initialized then
				delay_left, delay_right = target_delay_left, target_delay_right
			elseif
				math.abs(target_delay_left - delay_left) > frames * MAX_SLOPE or
				math.abs(target_delay_right - delay_right) > frames * MAX_SLOPE
			then
				target_delay_left, target_delay_right = delay_left, delay_right
				target_left = 0
				target_right = 0
			end

			any = true
			local correction = math.max(DELAY_CORRECTION * sample_rate, frames)
			local rate_left, rate_right = slot.tap_rate[t * 2], slot.tap_rate[t * 2 + 1]
			local slope_left = math.clamp(
				rate_left + (target_delay_left - delay_left - rate_left * frames) / correction,
				MIN_SLOPE,
				MAX_SLOPE
			)
			local slope_right = math.clamp(
				rate_right + (
						target_delay_right - delay_right - rate_right * frames
					) / correction,
				MIN_SLOPE,
				MAX_SLOPE
			)

			if target_delay_left == delay_left and target_delay_right == delay_right then
				slope_left, slope_right = 0, 0
			end

			local step_left = (target_left - gain_left) / frames
			local step_right = (target_right - gain_right) / frames
			local air_state, air_coefficient = voice.tap_air_state, voice.tap_air_coefficient
			local ct = t * 6

			if silent or not voice.initialized then
				for k = 0, 5 do
					air_coefficient[ct + k] = slot.tap_air[ct + k]
				end

				for k = 0, 11 do
					air_state[t * 12 + k] = 0
				end
			end

			local filtered = false

			for k = 0, 5 do
				if air_coefficient[ct + k] ~= 1 or slot.tap_air[ct + k] ~= 1 then
					filtered = true
				end

				air_coefficient[ct + k] = slot.tap_air[ct + k]
			end

			for i = 0, frames - 1 do
				gain_left = gain_left + step_left
				gain_right = gain_right + step_right
				local left = dsp.ReadLinear(source_history, mask, base + i - (delay_left + slope_left * (i + 1)))
				local right = dsp.ReadLinear(source_history, mask, base + i - (delay_right + slope_right * (i + 1)))

				if filtered then
					left = air_cascade(air_state, t * 12, air_coefficient, ct, left)
					right = air_cascade(air_state, t * 12 + 6, air_coefficient, ct, right)
				end

				tap_left[i] = left * gain_left
				tap_right[i] = right * gain_right
			end

			set_group_weights(slot.tap_height[t], slot.tap_front[t])

			for g = 0, CUE_GROUPS - 1 do
				local to = group_weights[g]
				local w = voice.initialized and voice.tap_group[t * CUE_GROUPS + g] or to

				if w ~= 0 or to ~= 0 then
					local cue_left = mixer.cue_left[g]
					local cue_right = mixer.cue_right[g]
					local step = (to - w) / frames

					for i = 0, frames - 1 do
						w = w + step
						cue_left[i] = cue_left[i] + tap_left[i] * w
						cue_right[i] = cue_right[i] + tap_right[i] * w
					end
				end

				voice.tap_group[t * CUE_GROUPS + g] = to
			end

			voice.tap_delay[t * 2] = delay_left + slope_left * frames
			voice.tap_delay[t * 2 + 1] = delay_right + slope_right * frames
			voice.tap_gain[t * 2] = target_left
			voice.tap_gain[t * 2 + 1] = target_right
		end
	end

	return any
end

local function filter_cues(mixer, out, frames)
	local state = mixer.state
	local c = mixer.cue_coefficients
	local states = mixer.cue_state

	for g = 0, CUE_GROUPS - 1 do
		local ci = g * 12

		for k = 0, 2 do
			dsp.PeakingCoefficients(
				c,
				ci + k * 4,
				state.cue_frequency[g * 3 + k],
				state.cue_gain[g * 3 + k],
				state.cue_q[k],
				mixer.sample_rate
			)
		end

		local b0a, a1a, b2a, a2a = c[ci], c[ci + 1], c[ci + 2], c[ci + 3]
		local b0b, a1b, b2b, a2b = c[ci + 4], c[ci + 5], c[ci + 6], c[ci + 7]
		local b0c, a1c, b2c, a2c = c[ci + 8], c[ci + 9], c[ci + 10], c[ci + 11]

		for ear = 0, 1 do
			local input = ear == 0 and mixer.cue_left[g] or mixer.cue_right[g]
			local si = (g * 2 + ear) * 6
			local s1a, s2a, s1b, s2b, s1c, s2c = states[si],
			states[si + 1],
			states[si + 2],
			states[si + 3],
			states[si + 4],
			states[si + 5]

			for i = 0, frames - 1 do
				local x = input[i]
				local y = b0a * x + s1a
				s1a = a1a * (x - y) + s2a
				s2a = b2a * x - a2a * y
				local z = b0b * y + s1b
				s1b = a1b * (y - z) + s2b
				s2b = b2b * y - a2b * z
				x = b0c * z + s1c
				s1c = a1c * (z - x) + s2c
				s2c = b2c * z - a2c * x
				local index = i * 2 + ear
				out[index] = out[index] + x
				input[i] = 0
			end

			states[si], states[si + 1], states[si + 2], states[si + 3], states[si + 4], states[si + 5] = s1a, s2a, s1b, s2b, s1c, s2c
		end
	end
end

local function render_sends(mixer, slot, voice, base, delay, slope, frames)
	local history = voice.history
	local mask = voice.history_size - 1
	local first, second = slot.send[0], slot.send[1]

	if first == 0 and second == 0 and voice.send[0] == 0 and voice.send[1] == 0 then
		return
	end

	local scratch = mixer.send_scratch
	local state, from, to = voice.send_air_state, voice.send_air_coefficient, slot.send_air
	local p1, p2, p3, p4, p5, p6 = state[0], state[1], state[2], state[3], state[4], state[5]
	local c1, c2, c3, c4, c5, c6 = from[0], from[1], from[2], from[3], from[4], from[5]
	local d1, d2, d3, d4, d5, d6 = (to[0] - c1) / frames,
	(to[1] - c2) / frames,
	(to[2] - c3) / frames,
	(to[3] - c4) / frames,
	(to[4] - c5) / frames,
	(to[5] - c6) / frames

	for i = 0, frames - 1 do
		local y = dsp.ReadLinear(history, mask, base + i - (delay + slope * (i + 1)))
		c1, c2, c3, c4, c5, c6 = c1 + d1, c2 + d2, c3 + d3, c4 + d4, c5 + d5, c6 + d6
		local v = (y - p1) * c1
		y = p1 + v
		p1 = y + v
		v = (y - p2) * c2
		y = p2 + v
		p2 = y + v
		v = (y - p3) * c3
		y = p3 + v
		p3 = y + v
		v = (y - p4) * c4
		y = p4 + v
		p4 = y + v
		v = (y - p5) * c5
		y = p5 + v
		p5 = y + v
		v = (y - p6) * c6
		y = p6 + v
		p6 = y + v
		scratch[i] = y
	end

	state[0], state[1], state[2], state[3], state[4], state[5] = p1, p2, p3, p4, p5, p6

	for k = 0, 5 do
		from[k] = to[k]
	end

	for b = 0, BUS_COUNT - 1 do
		local target = slot.send[b]
		local gain = voice.initialized and voice.send[b] or target

		if gain ~= 0 or target ~= 0 then
			local input = mixer.bus_input[b]
			local step = (target - gain) / frames

			for i = 0, frames - 1 do
				gain = gain + step
				input[i] = input[i] + scratch[i] * gain
			end

			voice.send[b] = target
		end
	end
end

-- log amplitude fluctuations of the mid and high bands from turbulence: low passed noise, normalized to the depth, with a gain that keeps the mean power
local function fill_scintillation(mixer, slot, voice, frames)
	local depth_mid, depth_high = slot.scintillation_depth[0], slot.scintillation_depth[1]

	if depth_mid < 0.01 and depth_high < 0.01 then
		voice.scintillation_state[0], voice.scintillation_state[1] = 0, 0
		return false
	end

	local coefficient = 1 - math.exp(-2 * math.pi * slot.scintillation_rate / mixer.sample_rate)
	local scale = math.sqrt((2 - coefficient) / coefficient * 3)
	local seed = voice.scintillation_seed
	local x_mid, x_high = voice.scintillation_state[0], voice.scintillation_state[1]
	local mid, high = mixer.scintillation_mid, mixer.scintillation_high
	local exp = math.exp

	for i = 0, frames - 1 do
		seed = bit.bxor(seed, bit.lshift(seed, 13))
		seed = bit.bxor(seed, bit.rshift(seed, 17))
		seed = bit.bxor(seed, bit.lshift(seed, 5))
		x_mid = x_mid + coefficient * (seed / 2147483648 - x_mid)
		seed = bit.bxor(seed, bit.lshift(seed, 13))
		seed = bit.bxor(seed, bit.rshift(seed, 17))
		seed = bit.bxor(seed, bit.lshift(seed, 5))
		x_high = x_high + coefficient * (seed / 2147483648 - x_high)
		mid[i] = exp(x_mid * scale * depth_mid - depth_mid * depth_mid)
		high[i] = exp(x_high * scale * depth_high - depth_high * depth_high)
	end

	voice.scintillation_seed = seed
	voice.scintillation_state[0], voice.scintillation_state[1] = x_mid, x_high
	return true
end

local function propagate(mixer, slot, voice, out, frames, block_end_time)
	local sample_rate = mixer.sample_rate
	local elapsed = math.clamp(block_end_time - slot.param_time, -0.05, 0.25)
	local base = voice.written - frames
	local snap = 0.05 * sample_rate
	local max_delay = 0
	local scintillating = fill_scintillation(mixer, slot, voice, frames)

	for ear = 0, 1 do
		local rate, change = slot.ear_rate[ear], slot.ear_rate_change[ear]
		local target = clamp_delay((slot.ear_delay[ear] + rate * elapsed + 0.5 * change * elapsed * elapsed) * sample_rate, voice)
		local delay, slope = track_delay(
			voice.ear_delay[ear],
			voice.ear_slope[ear],
			target,
			rate + change * (elapsed - 0.5 * frames / sample_rate),
			frames,
			voice.initialized,
			snap,
			DELAY_CORRECTION * sample_rate
		)

		if not voice.initialized then
			delay = clamp_delay(target - slot.ear_rate[ear] * frames, voice)
			slope = (target - delay) / frames

			for g = ear * 3, ear * 3 + 2 do
				voice.ear_gain[g] = slot.ear_gain[g]
				voice.ear_filter_frequency[g] = slot.ear_filter_frequency[g]
				voice.ear_filter_gain[g] = slot.ear_filter_gain[g]
			end

			for k = ear * 6, ear * 6 + 5 do
				voice.air_coefficient[k] = slot.ear_air[k]
			end

			for k = 0, 5 do
				voice.send_air_coefficient[k] = slot.send_air[k]
			end
		end

		render_ear(mixer, slot, voice, ear, base, delay, slope, out, frames, scintillating)
		voice.ear_delay[ear] = delay + slope * frames
		voice.ear_slope[ear] = slope
		max_delay = math.max(max_delay, voice.ear_delay[ear])
	end

	if render_taps(mixer, slot, voice, base, frames, elapsed) then
		mixer.cue_used = true
	end

	for t = 0, MAX_TAPS - 1 do
		if voice.tap_gain[t * 2] ~= 0 or voice.tap_gain[t * 2 + 1] ~= 0 then
			max_delay = math.max(max_delay, voice.tap_delay[t * 2], voice.tap_delay[t * 2 + 1])
		end
	end

	local start_delay = (
			voice.ear_delay[0] + voice.ear_delay[1] - (
				voice.ear_slope[0] + voice.ear_slope[1]
			) * frames
		) * 0.5
	render_sends(
		mixer,
		slot,
		voice,
		base,
		start_delay,
		(voice.ear_slope[0] + voice.ear_slope[1]) * 0.5,
		frames
	)
	voice.initialized = true
	return max_delay
end

local function mix_flat(mixer, slot, voice, out, frames)
	if slot.paused then return end

	local samples = ffi.cast("float*", slot.buffer)
	local channels = slot.channels
	local length = slot.buffer_len
	local looping = slot.looping
	local rate = slot.pitch * slot.sample_rate / mixer.sample_rate
	local position = slot.playback_pos
	local played = slot.played
	local inv_in = 1 / (math.max(slot.fade_in, DECLICK) * slot.sample_rate)
	local inv_out = 1 / (math.max(slot.fade_out, DECLICK) * slot.sample_rate)
	local volume = voice.volume
	local volume_step = (slot.volume - volume) / frames
	voice.volume = slot.volume

	if rate < 0 then rate = 0 end

	for i = 0, frames - 1 do
		local index = math.floor(position)

		if index >= length then
			if looping and length > 0 then
				position = position - length
				index = math.floor(position)
			else
				slot.active = false

				break
			end
		end

		local f = position - index
		volume = volume + volume_step
		local envelope = played * inv_in

		if envelope > 1 then envelope = 1 end

		if not looping then
			local fade_out = (length - position) * inv_out

			if fade_out < envelope then envelope = fade_out end
		end

		played = played + rate
		local gain = volume * envelope

		if channels == 2 then
			local next_index = index + 1 < length and index + 1 or (looping and 0 or index)
			local l0, r0 = samples[index * 2], samples[index * 2 + 1]
			local l1, r1 = samples[next_index * 2], samples[next_index * 2 + 1]
			out[i * 2] = out[i * 2] + (l0 + (l1 - l0) * f) * gain
			out[i * 2 + 1] = out[i * 2 + 1] + (r0 + (r1 - r0) * f) * gain
		else
			local next_index = index + 1 < length and index + 1 or (looping and 0 or index)
			local a = samples[index]
			local x = (a + (samples[next_index] - a) * f) * gain
			out[i * 2] = out[i * 2] + x
			out[i * 2 + 1] = out[i * 2 + 1] + x
		end

		position = position + rate
	end

	slot.playback_pos = position
	slot.played = played
end

local function mix_block(mixer, out, frames)
	local state = mixer.state
	local sample_rate = mixer.sample_rate
	local now = mixer.clock()
	local estimate = now - mixer.frames_done / sample_rate

	if mixer.frames_done == 0 then
		mixer.clock_offset = estimate
	else
		mixer.clock_offset = mixer.clock_offset + (estimate - mixer.clock_offset) * 0.01
	end

	state.clock_offset = mixer.clock_offset
	local block_end_time = mixer.clock_offset + (mixer.frames_done + frames) / sample_rate

	for i = 0, frames * 2 - 1 do
		out[i] = 0
	end

	for b = 0, BUS_COUNT - 1 do
		local input = mixer.bus_input[b]

		for i = 0, frames - 1 do
			input[i] = 0
		end
	end

	for i = 0, SLOT_COUNT - 1 do
		local slot = state.slots[i]
		local voice = mixer.voices[i]

		if slot.start_serial ~= voice.start_serial then
			if slot.active then
				reset_voice(mixer, i, voice, slot)
			else
				voice.idle = true
				slot.draining = false
			end
		end

		if slot.active or slot.draining then
			if not slot.spatial then
				mix_flat(mixer, slot, voice, out, frames)
				slot.draining = false
			else
				local was_idle = voice.idle

				if was_idle and slot.active and not slot.paused then
					ffi.fill(voice.history, voice.history_size * 4)
					ffi.fill(voice.tap_history, voice.history_size * 4)

					if slot.channels == 2 then
						ffi.fill(voice.side_history, voice.history_size * 4)
					end

					voice.idle = false
				end

				local size = history_size(mixer, slot)

				if size > voice.history_size then
					allocate_history(mixer, i, voice, slot, size, true)
				end

				emit(mixer, slot, voice, frames, sample_rate)
				update_ground(mixer, i, voice, slot, frames)

				if not voice.idle then
					local max_delay = propagate(mixer, slot, voice, out, frames, block_end_time)

					if voice.written - voice.last_signal > max_delay + frames + 8 then
						voice.idle = true

						if not voice.emitting or not slot.active then slot.draining = false end
					end
				end
			end
		end
	end

	if mixer.cue_used then
		mixer.cue_used = false
		mixer.cue_tail = CUE_TAIL_BLOCKS
	end

	if mixer.cue_tail > 0 then
		filter_cues(mixer, out, frames)
		mixer.cue_tail = mixer.cue_tail - 1

		if mixer.cue_tail == 0 then
			ffi.fill(mixer.cue_state, CUE_GROUPS * 12 * 8)
		end
	end

	local air_scale = state.air_scale
	local speed = mix.REVERB_SPEED_OF_SOUND
	local air_rate = state.air_flat_high * speed * air_scale
	local master_volume = state.master_volume * state.output_gain
	local dry_energy = 0

	for i = 0, frames * 2 - 1 do
		dry_energy = dry_energy + out[i] * out[i]
	end

	state.debug_dry_rms = math.sqrt(dry_energy / (frames * 2)) * master_volume
	local capturing = state.capture_frames + frames <= state.capture_capacity
	local capture_at = state.capture_frames * 2

	if capturing then
		for i = 0, frames * 2 - 1 do
			state.capture_dry[capture_at + i] = out[i] * master_volume
			state.capture_rev[capture_at + i] = 0
		end
	end

	for b = 0, BUS_COUNT - 1 do
		local bus = state.buses[b]
		local reverb = mixer.buses[b]

		for j = 0, dsp.REVERB_LINES - 1 do
			spatial.GetAirFilter(
				reverb.delay[j] / sample_rate * speed * air_scale,
				sample_rate,
				reverb.air_coefficient,
				j * 6 - 1
			)
		end

		spatial.GetAirFilter(
			dsp.REVERB_MEAN_DELAY * reverb.scale * speed * air_scale,
			sample_rate,
			reverb.air_coefficient,
			dsp.REVERB_LINES * 6 - 1
		)
		ffi.copy(mixer.bus_before, out, frames * 8)
		dsp.ProcessReverb(
			mixer.buses[b],
			mixer.bus_input[b],
			out,
			frames,
			sample_rate,
			bus.t60[0],
			bus.t60[1],
			60 / math.max(60 / bus.t60[2] - air_rate, 60 / mix.MAX_REVERB_T60),
			bus.predelay,
			bus.scale,
			bus.diffusion,
			bus.concentration,
			bus.ear_gain[0],
			bus.ear_gain[1],
			bus.ear_delay[0],
			bus.ear_delay[1]
		)
		local bus_energy = 0

		for i = 0, frames * 2 - 1 do
			local d = out[i] - mixer.bus_before[i]
			bus_energy = bus_energy + d * d
		end

		state.debug_bus_rms[b] = math.sqrt(bus_energy / (frames * 2)) * master_volume

		if capturing then
			for i = 0, frames * 2 - 1 do
				state.capture_rev[capture_at + i] = state.capture_rev[capture_at + i] + (
						out[i] - mixer.bus_before[i]
					) * master_volume
			end
		end
	end

	local raw_energy = 0

	for i = 0, frames * 2 - 1 do
		out[i] = out[i] * master_volume
		raw_energy = raw_energy + out[i] * out[i]
	end

	state.debug_raw_rms = math.sqrt(raw_energy / (frames * 2))
	state.debug_ear_reduction = dsp.ProcessEar(mixer.ear, out, frames, state.ear_threshold)

	if state.output_mode == 0 then
		state.debug_limiter_gain = dsp.ProcessLimiter(mixer.limiter, out, frames)
	else
		local soft = state.output_mode == 2
		local tanh = math.tanh
		local lowest = 1

		for i = 0, frames * 2 - 1 do
			local x = out[i]
			local y = soft and tanh(x) or math.max(-1, math.min(1, x))
			local gain = math.abs(x) > 1e-9 and math.abs(y / x) or 1

			if gain < lowest then lowest = gain end

			out[i] = y
		end

		state.debug_limiter_gain = lowest
	end

	if capturing then
		for i = 0, frames * 2 - 1 do
			state.capture_out[capture_at + i] = out[i]
		end

		state.capture_frames = state.capture_frames + frames
	end

	mixer.frames_done = mixer.frames_done + frames
	state.mixed_frames = mixer.frames_done
end

function mix.MixOutputBuffer(mixer, out_buffer, num_samples)
	local started = mixer.clock()
	local total = num_samples / 2
	local done = 0

	while done < total do
		local frames = math.min(total - done, mixer.max_frames)
		mix_block(mixer, out_buffer + done * 2, frames)
		done = done + frames
	end

	local peak_left = 0
	local peak_right = 0

	for i = 0, num_samples - 1, 2 do
		local left = math.abs(out_buffer[i])
		local right = math.abs(out_buffer[i + 1])

		if left > peak_left then peak_left = left end

		if right > peak_right then peak_right = right end
	end

	local state = mixer.state
	state.debug_mix_callbacks = state.debug_mix_callbacks + 1
	state.debug_output_peak_left = peak_left
	state.debug_output_peak_right = peak_right
	state.debug_mix_seconds = state.debug_mix_seconds + (
			mixer.clock() - started - state.debug_mix_seconds
		) * 0.05
end

return mix
