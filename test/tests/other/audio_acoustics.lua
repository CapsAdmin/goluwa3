local T = import("test/environment.lua")
local ffi = require("ffi")
local audio = import("goluwa/audio.lua")
local mix = import("goluwa/audio/mix.lua")
local dsp = import("goluwa/audio/dsp.lua")
local acoustics = import("goluwa/audio/acoustics.lua")
local acoustics_cpu = import("goluwa/audio/acoustics_cpu.lua")
local ground = import("goluwa/audio/ground.lua")
local explosion = import("goluwa/audio/explosion.lua")
local spatial = import("goluwa/audio/spatial.lua")
local pvars = import("goluwa/cli/pvars.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local FS = 44100
local LEAD = 200

local function with_offline_mixer(cb)
	local saved_state, saved_sounds, saved_clock, saved_motion = audio.state, audio.active_sounds, audio.clock, audio.listener_motion
	local saved_acoustics = audio.acoustics
	local saved_position, saved_forward, saved_up = audio.listener_position, audio.listener_forward, audio.listener_up
	local saved_atmosphere = {
		audio.turbulence,
		audio.temperature_gradient,
		spatial.TURBULENCE_WIND,
		spatial.WIND_GRADIENT,
	}
	audio.turbulence, audio.temperature_gradient, spatial.TURBULENCE_WIND, spatial.WIND_GRADIENT = 0, 0, 0, 0
	local ctx = {time = 0}
	audio.state = audio.CreateMixerState()
	audio.state.ear_threshold = 100
	audio.active_sounds = {}
	audio.listener_motion = {}
	audio.acoustics = nil
	audio.clock = function()
		return ctx.time
	end
	ctx.mixer = mix.CreateMixer(audio.state, FS, 512)
	ctx.mixer.clock = audio.clock
	audio.SetListenerPosition(Vec3(0, 0, 0))
	audio.SetListenerOrientation(Vec3(0, 0, -1), Vec3(0, 1, 0))

	function ctx.Render(seconds, on_frame)
		local total = math.floor(seconds * FS)
		local latency = ctx.mixer.limiter.length - 1
		local mixed = total + latency
		local out = ffi.new("float[?]", mixed * 2)
		local done = 0
		local next_update = 0

		while done < mixed do
			local frames = math.min(512, mixed - done)
			local now = ctx.mixer.frames_done / FS

			while now >= next_update do
				ctx.time = next_update

				if on_frame then on_frame(ctx.time) end

				audio.Update()
				next_update = next_update + 1 / 60
			end

			ctx.time = now
			mix.MixOutputBuffer(ctx.mixer, out + done * 2, frames * 2)
			done = done + frames
		end

		local trimmed = ffi.new("float[?]", total * 2)
		ffi.copy(trimmed, out + latency * 2, total * 8)
		return trimmed, total
	end

	local ok, err = pcall(cb, ctx)
	audio.state, audio.active_sounds, audio.clock, audio.listener_motion = saved_state, saved_sounds, saved_clock, saved_motion
	audio.acoustics = saved_acoustics
	audio.listener_position, audio.listener_forward, audio.listener_up = saved_position, saved_forward, saved_up
	audio.turbulence, audio.temperature_gradient, spatial.TURBULENCE_WIND, spatial.WIND_GRADIENT = unpack(saved_atmosphere)

	if not ok then error(err, 0) end
end

local function mono_source(count, fill)
	local data = ffi.new("float[?]", count)

	for i = 0, count - 1 do
		data[i] = fill(i)
	end

	return audio.CreateSource{data = data, samples = count, channels = 1, sample_rate = FS}
end

local function peak_index(out, total, channel)
	local best, at = 0, 0

	for i = 0, total - 1 do
		local v = math.abs(out[i * 2 + channel])

		if v > best then best, at = v, i end
	end

	return at
end

local function frequency(out, channel, from, to)
	local first, last, count = nil, nil, 0
	local prev = out[from * 2 + channel]

	for i = from + 1, to do
		local v = out[i * 2 + channel]

		if prev < 0 and v >= 0 then
			local t = i - 1 + prev / (prev - v)

			if first then count = count + 1 else first = t end

			last = t
		end

		prev = v
	end

	return count / ((last - first) / FS)
end

T.Test("audio a far sound on a curved path is delayed from where it was, not from where its velocity points", function()
	with_offline_mixer(function(ctx)
		local c = audio.speed_of_sound
		local radius, speed, omega = 1000, 150, 0.15
		local center = Vec3(0, 50, -4000)

		local function position(t)
			return center + Vec3(math.cos(omega * t) * radius, 0, math.sin(omega * t) * radius)
		end

		local source = mono_source(64, function()
			return 0
		end)
		source:SetLooping(true)
		source:SetReferenceDistance(1)
		source:SetPosition(position(0))
		source:Play()

		for _ = 1, 30 * 60 do
			ctx.time = ctx.time + 1 / 60
			source:SetPosition(position(ctx.time))
			audio.Update()
		end

		local ear = audio.listener_position

		local function exact_delay(now)
			local lo, hi = 0, 25

			for _ = 1, 60 do
				local tau = (lo + hi) / 2

				if c * tau < (position(now - tau) - ear):GetLength() then
					lo = tau
				else
					hi = tau
				end
			end

			return (lo + hi) / 2
		end

		local exact = exact_delay(ctx.time)
		local exact_rate = (exact_delay(ctx.time + 0.01) - exact_delay(ctx.time - 0.01)) / 0.02
		local slot = audio.state.slots[source.slot]
		T(exact)[">"](8)
		T(math.abs(slot.ear_delay[0] - exact))["<"](0.005)
		T(math.abs(slot.ear_delay[1] - exact))["<"](0.005)
		T(math.abs(exact_rate))[">"](0.05)
		T(math.abs(slot.ear_rate[0] - exact_rate))["<"](0.01)
		local motion = source.audio_motion
		local ground = Vec3(0, 1, 0)
		local image = Vec3(motion.position.x, -motion.position.y, motion.position.z)
		local image_velocity = Vec3(motion.velocity.x, -motion.velocity.y, motion.velocity.z)
		local echo_delay = spatial.PathTiming(motion, image, image_velocity, ear, Vec3(0, 0, 0), Vec3(0, 0, 0), c, 0, ground, 0)
		local lo, hi = 0, 25

		for _ = 1, 60 do
			local tau = (lo + hi) / 2
			local p = position(ctx.time - tau)

			if c * tau < (Vec3(p.x, -p.y, p.z) - ear):GetLength() then
				lo = tau
			else
				hi = tau
			end
		end

		T(math.abs(echo_delay - (lo + hi) / 2))["<"](0.005)
		audio.StopAll()
	end)
end)

T.Test("audio sounds keep as much delay history as their distance needs", function()
	with_offline_mixer(function(ctx)
		local count = 300

		local function tone()
			return mono_source(count, function(i)
				return math.sin(2 * math.pi * 300 * i / FS) * (
						0.5 - 0.5 * math.cos(2 * math.pi * i / count)
					)
			end)
		end

		local near = tone()
		near:SetPosition(Vec3(0, 0, -30))
		near:Play()
		local far = tone()
		far:SetReferenceDistance(1)
		far:SetPosition(Vec3(0, 0, -3000))
		far:Play()
		local near_slot, far_slot = near.slot, far.slot
		local out, total = ctx.Render(10)
		local best, at = 0, 0

		for i = 5 * FS, total - 1 do
			if math.abs(out[i * 2]) > best then best, at = math.abs(out[i * 2]), i end
		end

		T(math.abs(at / FS - 3000 / audio.speed_of_sound))["<"](0.03)
		T(ctx.mixer.voices[near_slot].history_size)["=="](mix.MIN_HISTORY_SIZE)
		T(ctx.mixer.voices[far_slot].history_size)[">="](math.ceil(3000 / audio.speed_of_sound * FS))
		audio.StopAll()
	end)
end)

T.Test("audio a sound moving far away grows its history without losing what is in flight", function()
	with_offline_mixer(function(ctx)
		local source = mono_source(FS * 4, function(i)
			return 0.5 * math.sin(2 * math.pi * 200 * i / FS)
		end)
		source:SetReferenceDistance(1)
		source:SetPosition(Vec3(0, 0, -100))
		source:Play()
		ctx.Render(1)
		T(ctx.mixer.voices[source.slot].history_size)["=="](mix.MIN_HISTORY_SIZE)
		source:SetPosition(Vec3(0, 0, -2500))
		local out, total = ctx.Render(1)
		T(ctx.mixer.voices[source.slot].history_size)[">"](mix.MIN_HISTORY_SIZE)

		for i = 0, total * 2 - 1 do
			T(out[i] == out[i])["=="](true)
		end

		audio.StopAll()
	end)
end)

T.Test("audio propagation delay and interaural time difference", function()
	with_offline_mixer(function(ctx)
		local front = mono_source(64 + LEAD, function(i)
			return i == LEAD and 1 or 0
		end)
		front:SetPosition(Vec3(0, 0, -34.33))
		front:Play()
		local out, total = ctx.Render(0.2)
		T(math.abs(peak_index(out, total, 0) - LEAD - 34.33 / audio.speed_of_sound * FS))["<="](2)
		T(math.abs(peak_index(out, total, 0) - peak_index(out, total, 1)))["<="](1)
		audio.StopAll()
		local right = mono_source(64 + LEAD, function(i)
			return i == LEAD and 1 or 0
		end)
		right:SetPosition(Vec3(3, 0, 0))
		right:Play()
		out, total = ctx.Render(0.1)
		local itd = (peak_index(out, total, 0) - peak_index(out, total, 1)) / FS
		T(math.abs(itd - audio.ear_distance / audio.speed_of_sound))["<="](0.00005)
	end)
end)

T.Test("audio band gains of a sound shape what it emits", function()
	local function measure(hz, gains)
		local level

		with_offline_mixer(function(ctx)
			local sine = mono_source(FS, function(i)
				return math.sin(2 * math.pi * hz * i / FS) * 0.5
			end)
			sine:SetLooping(true)
			sine:SetPosition(Vec3(0, 0, -2))
			sine:SetBandGains(gains)
			sine:Play()
			local out, total = ctx.Render(0.5)
			local from, sum = math.floor(total / 2), 0

			for i = from, total - 1 do
				sum = sum + out[i * 2] ^ 2
			end

			level = math.sqrt(sum / (total - from))
			audio.StopAll()
		end)

		return level
	end

	local tilt = Vec3(1, 0.6, 0.3)
	T(measure(250, tilt) / measure(250, Vec3(1, 1, 1)))["~"](1, 0.1)
	T(measure(1500, tilt) / measure(1500, Vec3(1, 1, 1)))["~"](0.6, 0.1)
	T(measure(8000, tilt) / measure(8000, Vec3(1, 1, 1)))["~"](0.3, 0.1)
end)

T.Test("audio pinna cues move the notch with elevation and filter only the ears they face", function()
	local enabled = audio.pinna_cues:Get()
	pvars.SetSession("audio_pinna", 1)

	local function paths(position)
		local result

		with_offline_mixer(function()
			local snd = mono_source(64, function()
				return 0
			end)
			snd:SetPosition(position)
			result = audio.ComputePaths(snd)
		end)

		return result
	end

	local below, level, above = paths(Vec3(0, -2, -2)), paths(Vec3(0, 0, -3)), paths(Vec3(0, 2, -2))
	T(below.ear_filter_frequency[1] < level.ear_filter_frequency[1])["=="](true)
	T(level.ear_filter_frequency[1] < above.ear_filter_frequency[1])["=="](true)
	T(level.ear_filter_frequency[1])["~"](spatial.PINNA_NOTCH.frequency, 1)
	T(level.ear_filter_gain[2])["=="](0)
	T(above.ear_filter_gain[2])[">"](0)
	local right = paths(Vec3(3, 0, -0.5))
	T(right.ear_filter_gain[4] < right.ear_filter_gain[1])["=="](true)

	local function band_level(pinna, hz)
		pvars.SetSession("audio_pinna", pinna)
		local level

		with_offline_mixer(function(ctx)
			local seed = 1
			local noise = mono_source(FS, function()
				seed = (seed * 1103515245 + 12345) % 2147483648
				return seed / 2147483648 - 0.5
			end)
			noise:SetLooping(true)
			noise:SetPosition(Vec3(0, 0, -3))
			noise:Play()
			local out, total = ctx.Render(0.6)
			local w0 = 2 * math.pi * hz / FS
			local alpha = math.sin(w0) / 24
			local a0 = 1 + alpha
			local b0, b2, a1, a2 = alpha / a0, -alpha / a0, -2 * math.cos(w0) / a0, (1 - alpha) / a0
			local x1, x2, y1, y2, sum = 0, 0, 0, 0, 0

			for i = math.floor(total / 3), total - 1 do
				local x = out[i * 2]
				local y = b0 * x + b2 * x2 - a1 * y1 - a2 * y2
				x2, x1, y2, y1 = x1, x, y1, y
				sum = sum + y * y
			end

			level = sum
			audio.StopAll()
		end)

		return level
	end

	local notch = spatial.PINNA_NOTCH.frequency
	T(10 * math.log10(band_level(1, notch) / band_level(0, notch)))["<"](-4)
	T(math.abs(10 * math.log10(band_level(1, 500) / band_level(0, 500))))["<"](0.5)
	pvars.SetSession("audio_pinna", enabled)
end)

T.Test("audio reflections reach each ear at their own time with the ear filters of their direction", function()
	local enabled = audio.pinna_cues:Get()

	local function reflection(height, front, side, strength)
		pvars.SetSession("audio_pinna", strength)
		local out, total

		with_offline_mixer(function(ctx)
			local click = mono_source(64 + LEAD, function(i)
				return i == LEAD and 1 or 0
			end)
			click:SetPosition(Vec3(0, 0, -2))
			local itd = side * audio.ear_distance / audio.speed_of_sound * 0.5
			click.audio_environment = {
				taps = {
					{
						delay_left = 0.036 + itd,
						delay_right = 0.036 - itd,
						rate_left = 0,
						rate_right = 0,
						height = height,
						front = front,
						gain_left = 0.5,
						gain_right = 0.5,
						air = {1, 1, 1, 1, 1, 1},
					},
				},
				tap_band = {1, 1, 1},
				send = {0, 0},
			}
			click:Play()
			out, total = ctx.Render(0.1)
			audio.StopAll()
		end)

		return out, total
	end

	local function tone(out, hz)
		local from, to = math.floor(0.03 * FS), math.floor(0.06 * FS)
		local re, im = 0, 0

		for i = from, to do
			local w = (0.5 - 0.5 * math.cos(2 * math.pi * (i - from) / (to - from))) * out[i * 2]
			re = re + w * math.cos(2 * math.pi * hz * i / FS)
			im = im + w * math.sin(2 * math.pi * hz * i / FS)
		end

		return re * re + im * im
	end

	local out, total = reflection(0, 0, 1, 1)
	local first = math.floor(0.03 * FS)
	local left = peak_index(out + first * 2, total - first, 0)
	local right = peak_index(out + first * 2, total - first, 1)
	T(left - right)["~"](audio.ear_distance / audio.speed_of_sound * FS, 2)
	T(
		10 * math.log10(
				tone(reflection(-0.7, 0.71, 0, 1), 5500) / tone(reflection(-0.7, 0.71, 0, 0), 5500)
			)
	)["<"](-3)
	T(
		10 * math.log10(tone(reflection(0.7, 0.71, 0, 1), 7500) / tone(reflection(0.7, 0.71, 0, 0), 7500))
	)[">"](3)
	pvars.SetSession("audio_pinna", enabled)
end)

T.Test("audio reverb keeps its pitch and level when the room size changes", function()
	local frames = FS * 2

	local function render(fill, scale_from, scale_to, change)
		local reverb = dsp.CreateReverb(FS)
		local input = ffi.new("float[?]", frames)
		local out = ffi.new("float[?]", frames * 2)

		for i = 0, frames - 1 do
			input[i] = fill(i)
		end

		for i = 0, frames - 1, 512 do
			dsp.ProcessReverb(
				reverb,
				input + i,
				out + i * 2,
				math.min(512, frames - i),
				FS,
				2.5,
				2.5,
				2.5,
				0.02,
				i >= change * FS and scale_to or scale_from,
				1,
				0,
				1,
				1,
				0,
				0
			)
		end

		return out
	end

	local tone = render(
		function(i)
			return i < FS / 2 and math.sin(2 * math.pi * 1000 * i / FS) * 0.5 or 0
		end,
		1,
		3,
		0.55
	)
	T(frequency(tone, 0, math.floor(0.8 * FS), math.floor(1.2 * FS)))["~"](1000, 10)
	local seed = 5

	local function noise()
		seed = (seed * 1103515245 + 12345) % 2147483648
		return (seed / 2147483648 - 0.5) * 0.3
	end

	local function level(out)
		local sum = 0

		for i = math.floor(1.05 * FS), math.floor(1.4 * FS) do
			sum = sum + out[i * 2] ^ 2 + out[i * 2 + 1] ^ 2
		end

		return sum
	end

	local changed = level(render(noise, 1, 3, 1))
	seed = 5
	T(math.abs(10 * math.log10(changed / level(render(noise, 1, 1, 1)))))["<"](1)
end)

T.Test("audio reverb is coherent between the ears below a few hundred hertz and not above", function()
	local reverb = dsp.CreateReverb(FS)
	local frames = FS * 2
	local input = ffi.new("float[?]", frames)
	local out = ffi.new("float[?]", frames * 2)
	local seed = 3

	for i = 0, FS / 4 do
		seed = (seed * 1103515245 + 12345) % 2147483648
		input[i] = seed / 2147483648 - 0.5
	end

	for i = 0, frames - 1, 512 do
		dsp.ProcessReverb(
			reverb,
			input + i,
			out + i * 2,
			math.min(512, frames - i),
			FS,
			1.5,
			1.4,
			0.9,
			0.02,
			1,
			1,
			0,
			1,
			1,
			0,
			0
		)
	end

	local function coherence(hz)
		local w0 = 2 * math.pi * hz / FS
		local alpha = math.sin(w0) / 4
		local a0 = 1 + alpha
		local b0, b2, a1, a2 = alpha / a0, -alpha / a0, -2 * math.cos(w0) / a0, (1 - alpha) / a0
		local l1, l2, ly1, ly2, r1, r2, ry1, ry2 = 0, 0, 0, 0, 0, 0, 0, 0
		local ll, rr, lr = 0, 0, 0

		for i = 0, frames - 1 do
			local l = b0 * out[i * 2] + b2 * l2 - a1 * ly1 - a2 * ly2
			l2, l1, ly2, ly1 = l1, out[i * 2], ly1, l
			local r = b0 * out[i * 2 + 1] + b2 * r2 - a1 * ry1 - a2 * ry2
			r2, r1, ry2, ry1 = r1, out[i * 2 + 1], ry1, r
			ll, rr, lr = ll + l * l, rr + r * r, lr + l * r
		end

		return lr / math.sqrt(ll * rr)
	end

	T(coherence(125))[">"](0.8)
	T(math.abs(coherence(2000)))["<"](0.25)
end)

T.Test("audio doppler comes from motion through the delay line", function()
	local c = audio.speed_of_sound

	local function measure(source_velocity, listener_velocity)
		local f

		with_offline_mixer(function(ctx)
			local sine = mono_source(FS * 2, function(i)
				return math.sin(2 * math.pi * 1000 * i / FS) * 0.5
			end)
			sine:SetLooping(true)
			local start = Vec3(0, 0, -150)
			sine:SetPosition(start)
			sine:Play()
			local out = ctx.Render(1.3, function(t)
				sine:SetPosition(start + source_velocity * t)
				audio.SetListenerPosition(listener_velocity * t)
			end)
			f = frequency(out, 0, math.floor(0.8 * FS), math.floor(1.25 * FS))
		end)

		return f
	end

	T(math.abs(measure(Vec3(0, 0, 34.33), Vec3(0, 0, 0)) - 1000 * c / (c - 34.33)))["<="](1)
	T(math.abs(measure(Vec3(0, 0, -34.33), Vec3(0, 0, 0)) - 1000 * c / (c + 34.33)))["<="](1)
	T(math.abs(measure(Vec3(0, 0, 0), Vec3(0, 0, -34.33)) - 1000 * (c + 34.33) / c))["<="](1)
end)

T.Test("audio reverb bus decays at its T60 with unit energy", function()
	for _, t60 in ipairs({0.5, 2}) do
		local reverb = dsp.CreateReverb(FS)
		local frames = FS * 3
		local input = ffi.new("float[?]", frames)
		local out = ffi.new("float[?]", frames * 2)
		input[500] = 1

		for i = 0, frames - 1, 512 do
			dsp.ProcessReverb(
				reverb,
				input + i,
				out + i * 2,
				math.min(512, frames - i),
				FS,
				t60,
				t60,
				t60,
				0.03,
				1,
				1,
				0,
				1,
				1,
				0,
				0
			)
		end

		local tail = ffi.new("double[?]", frames + 1)

		for i = frames - 1, 0, -1 do
			tail[i] = tail[i + 1] + out[i * 2] * out[i * 2]
		end

		local from, to

		for i = 0, frames - 1 do
			local db = 10 * math.log10(tail[i] / tail[0])

			if not from and db <= -5 then from = i end

			if db <= -25 then
				to = i

				break
			end
		end

		T(math.abs((to - from) / FS * 3 - t60) / t60)["<="](0.1)
		T(math.abs(tail[0] - 1))["<="](0.15)
	end
end)

local function reverb_band_t20(t60s, scale, diffusion)
	local reverb = dsp.CreateReverb(FS)
	local frames = FS * 5
	local input = ffi.new("float[?]", frames)
	local out = ffi.new("float[?]", frames * 2)
	input[500] = 1

	for i = 0, frames - 1, 512 do
		dsp.ProcessReverb(
			reverb,
			input + i,
			out + i * 2,
			math.min(512, frames - i),
			FS,
			t60s[1],
			t60s[2],
			t60s[3],
			0.03,
			scale,
			diffusion,
			0,
			1,
			1,
			0,
			0
		)
	end

	local result = {}

	for band = 1, 3 do
		local w0 = 2 * math.pi * dsp.BAND_CENTERS[band] / FS
		local alpha = math.sin(w0) / 2.8
		local a0 = 1 + alpha
		local b0, b2, a1, a2 = alpha / a0, -alpha / a0, -2 * math.cos(w0) / a0, (1 - alpha) / a0
		local x1, x2, y1, y2 = 0, 0, 0, 0
		local energy = ffi.new("double[?]", frames + 1)

		for i = 0, frames - 1 do
			local x = out[i * 2]
			local y = b0 * x + b2 * x2 - a1 * y1 - a2 * y2
			x2, x1, y2, y1 = x1, x, y1, y
			energy[i] = y * y
		end

		for i = frames - 1, 0, -1 do
			energy[i] = energy[i] + energy[i + 1]
		end

		local from, to

		for i = 0, frames - 1 do
			local level = 10 * math.log10(energy[i] / energy[0])

			if not from and level <= -5 then from = i end

			if level <= -25 then
				to = i

				break
			end
		end

		result[band] = (to - from) / FS * 3
	end

	return result
end

T.Test("audio reverb bus decays at each band's own T60, also with sparse lines", function()
	for _, case in ipairs{
		{{2.77, 2.68, 1.51}, 1, 1},
		{{1.6, 1.4, 0.8}, 1, 1},
		{{2.77, 2.68, 1.51}, 3.4, 0},
	} do
		local measured = reverb_band_t20(case[1], case[2], case[3])

		for band = 1, 3 do
			T(math.abs(measured[band] - case[1][band]) / case[1][band])["<="](0.15)
		end
	end
end)

local function box_material(absorption, scattering)
	return acoustics.NewMaterial(
		{absorption, absorption, absorption},
		scattering or {0.2, 0.2, 0.2},
		acoustics.DEFAULT_MATERIAL.density,
		acoustics.DEFAULT_MATERIAL.surface_mass,
		{1, 1, 1},
		{0, 0, 0}
	)
end

local function box_tracer(min, max, absorption, budget, open_top, material, hole)
	local tracer = acoustics_cpu.New(budget)
	local a = material or box_material(absorption)

	function tracer:Trace(ox, oy, oz, dx, dy, dz, tmin, tmax)
		local best, nx, ny, nz = math.huge, 0, 0, 0

		if dx ~= 0 then
			local t = ((dx > 0 and max.x or min.x) - ox) / dx

			if t < best then best, nx, ny, nz = t, dx > 0 and -1 or 1, 0, 0 end
		end

		if dy ~= 0 then
			local t = ((dy > 0 and max.y or min.y) - oy) / dy

			if t < best then best, nx, ny, nz = t, 0, dy > 0 and -1 or 1, 0 end
		end

		if dz ~= 0 then
			local t = ((dz > 0 and max.z or min.z) - oz) / dz

			if t < best then best, nx, ny, nz = t, 0, 0, dz > 0 and -1 or 1 end
		end

		if best < tmin or best > tmax or open_top and ny == -1 then return nil end

		if hole and hole(ox + dx * best, oy + dy * best, oz + dz * best, nx, ny, nz) then
			return nil
		end

		return best, nx, ny, nz, a
	end

	return tracer
end

T.Test("audio acoustics matches Eyring in a box room and finds every wall reflection", function()
	with_offline_mixer(function(ctx)
		local W, H, D, alpha = 10, 4, 8, 0.1
		local tracer = box_tracer(
			Vec3(-W / 2, 0, -D / 2),
			Vec3(W / 2, H, D / 2),
			alpha,
			{
				rays = 256,
				bounces = 10,
				samples = 128,
				sources = 1,
				fresnel = 2,
				reflection_sources = 1,
			}
		)
		audio.acoustics = acoustics.New(audio, tracer)
		local listener = Vec3(1.3, 1.7, 0.6)
		local source = Vec3(-2.5, 1.2, -1.1)
		audio.SetListenerPosition(listener)
		local snd = mono_source(64, function()
			return 0
		end)
		snd:SetLooping(true)
		snd:SetPosition(source)
		snd:Play()

		for _ = 1, 40 do
			ctx.time = ctx.time + 1 / 60
			audio.Update()
		end

		local profile = audio.acoustics.profile
		local V = W * H * D
		local S = 2 * (W * H + W * D + H * D)

		for band = 1, 3 do
			local eyring = 0.161 * V / (
					-S * math.log(1 - alpha) + 4 * acoustics.AirEnergyPerMeter(band) * V
				)
			T(math.abs(profile.t60[band] - eyring) / eyring)["<="](0.1)
			T(math.abs(audio.state.buses[0].t60[band - 1] - eyring) / eyring)["<="](0.1)
		end

		T(math.abs(profile.volume - V) / V)["<="](0.05)
		T(math.abs(profile.mean_free_path - 4 * V / S) / (4 * V / S))["<="](0.05)
		local env = snd.audio_environment
		local delays = {}

		for _, tap in pairs(env.taps) do
			delays[#delays + 1] = tap.delay
		end

		T(#delays)["=="](6)
		local floor_image = Vec3(source.x, -source.y, source.z)
		local floor_delay = (floor_image - listener):GetLength() / audio.speed_of_sound
		local found = false

		for _, delay in ipairs(delays) do
			if math.abs(delay - floor_delay) < 0.0002 then found = true end
		end

		T(found)["=="](true)
		local ceiling_delay = (
				Vec3(source.x, 2 * H - source.y, source.z) - listener
			):GetLength() / audio.speed_of_sound
		local right_delay = (
				Vec3(W - source.x, source.y, source.z) - listener
			):GetLength() / audio.speed_of_sound
		local checked = 0

		for _, tap in pairs(env.taps) do
			if math.abs(tap.delay - floor_delay) < 0.0002 then
				T(tap.height)["<"](-0.3)
				checked = checked + 1
			elseif math.abs(tap.delay - ceiling_delay) < 0.0002 then
				T(tap.height)[">"](0.3)
				checked = checked + 1
			elseif math.abs(tap.delay - right_delay) < 0.0002 then
				T(tap.delay_right < tap.delay_left)["=="](true)
				checked = checked + 1
			end

			T(math.abs(tap.delay_left - tap.delay_right))["<="](audio.ear_distance / audio.speed_of_sound + 1e-6)
		end

		T(checked)["=="](3)
		T(env.send[1])[">"](0.5)
		T(env.occlusion[2])["=="](1)
		local clap = mono_source(64, function()
			return 0
		end)
		clap:SetPosition(Vec3(2.1, 1.4, 1.9))
		clap:Play()
		local clap_env = clap.audio_environment
		local clap_taps = 0

		for _ in pairs(clap_env.taps) do
			clap_taps = clap_taps + 1
		end

		T(clap_taps)["=="](6)
		T(clap_env.send[1])[">"](0.5)
		audio.StopAll()
	end)
end)

T.Test("audio a one shot starts with the reverb of its distance, not of a sound at the listener", function()
	with_offline_mixer(function(ctx)
		audio.acoustics = acoustics.New(
			audio,
			box_tracer(
				Vec3(-5, 0, -4),
				Vec3(5, 4, 4),
				0.1,
				{
					rays = 256,
					bounces = 10,
					samples = 128,
					sources = 1,
					fresnel = 2,
					reflection_sources = 1,
				}
			)
		)
		local listener = Vec3(1.3, 1.7, 0.6)
		audio.SetListenerPosition(listener)
		local keep = mono_source(64, function()
			return 0
		end)
		keep:SetLooping(true)
		keep:SetPosition(Vec3(-2.5, 1.2, -1.1))
		keep:Play()

		for _ = 1, 40 do
			ctx.time = ctx.time + 1 / 60
			audio.Update()
		end

		local function one_shot_energy(offset)
			local shot = mono_source(64, function()
				return 0
			end)
			shot:SetPosition(listener + offset)
			shot:Play()
			local energy = shot.audio_environment.energy
			shot:Stop()
			return energy
		end

		local near_offset, far_offset = Vec3(-1, 0, 0), Vec3(-6, 0, 0)
		local near, far = one_shot_energy(near_offset), one_shot_energy(far_offset)
		local t60 = audio.acoustics.ambient_reverb.t60[2]
		local expected = math.exp(
			-13.82 * (
					far_offset:GetLength() - near_offset:GetLength()
				) / (
					audio.speed_of_sound * t60
				)
		)
		T(math.abs(far / near / expected - 1))["<"](0.02)
		audio.StopAll()
	end)
end)

T.Test("audio acoustics follows the listener into another room within a few frames", function()
	with_offline_mixer(function(ctx)
		local budget = {
			rays = 256,
			bounces = 10,
			samples = 128,
			sources = 1,
			fresnel = 2,
			reflection_sources = 1,
		}
		local alpha = 0.1
		local small = box_tracer(Vec3(-2, 0, -2), Vec3(2, 3, 2), alpha, budget)
		local large = box_tracer(Vec3(96, 0, -12), Vec3(124, 10, 12), alpha, budget)
		audio.acoustics = acoustics.New(audio, small)
		audio.SetListenerPosition(Vec3(0.3, 1.7, 0.2))

		for _ = 1, 40 do
			ctx.time = ctx.time + 1 / 60
			audio.Update()
		end

		audio.acoustics.tracer = large
		audio.SetListenerPosition(Vec3(110.3, 1.7, 0.2))

		for _ = 1, 12 do
			ctx.time = ctx.time + 1 / 60
			audio.Update()
		end

		local V = 28 * 10 * 24
		local S = 2 * (28 * 10 + 28 * 24 + 10 * 24)
		local eyring = 0.161 * V / (-S * math.log(1 - alpha) + 4 * acoustics.AirEnergyPerMeter(2) * V)
		T(math.abs(audio.acoustics.profile.t60[2] - eyring) / eyring)["<="](0.1)
	end)
end)

T.Test("audio acoustics keeps the long late tail of a room without a roof", function()
	with_offline_mixer(function(ctx)
		audio.acoustics = acoustics.New(
			audio,
			box_tracer(
				Vec3(-5, 0, -6),
				Vec3(5, 3.5, 6),
				0.02,
				{
					rays = 256,
					bounces = 8,
					samples = 128,
					sources = 1,
					fresnel = 2,
					reflection_sources = 1,
				},
				true
			)
		)
		audio.SetListenerPosition(Vec3(-1, 1.7, -0.6))

		for _ = 1, 40 do
			ctx.time = ctx.time + 1 / 60
			audio.Update()
		end

		T(audio.state.buses[0].t60[1] / audio.acoustics.profile.t60[2])[">="](1.5)
	end)
end)

local function ground_tracer(boxes, absorption, budget, scattering)
	local tracer = acoustics_cpu.New(budget)
	local material = box_material(absorption, scattering)

	function tracer:Trace(ox, oy, oz, dx, dy, dz, tmin, tmax)
		local best, nx, ny, nz = math.huge, 0, 0, 0

		if dy < 0 then best, nx, ny, nz = -oy / dy, 0, 1, 0 end

		for _, b in ipairs(boxes) do
			local near, far, axis, side = -math.huge, math.huge, nil, 0

			for i = 1, 3 do
				local o = i == 1 and ox or i == 2 and oy or oz
				local d = i == 1 and dx or i == 2 and dy or dz
				local lo, hi = b[i * 2 - 1], b[i * 2]

				if d == 0 then
					if o < lo or o > hi then far = -math.huge end
				else
					local t1, t2, s = (lo - o) / d, (hi - o) / d, -1

					if t1 > t2 then t1, t2, s = t2, t1, 1 end

					if t1 > near then near, axis, side = t1, i, s end

					if t2 < far then far = t2 end
				end
			end

			if axis and near <= far and near > 1e-6 and near < best then
				best = near
				nx, ny, nz = 0, 0, 0

				if axis == 1 then nx = side elseif axis == 2 then ny = side else nz = side end
			end
		end

		if best == math.huge or best < tmin or best > tmax then return nil end

		return best, nx, ny, nz, material
	end

	return tracer
end

T.Test("audio acoustics gives open ground with one building an echo and no reverb tail", function()
	with_offline_mixer(function(ctx)
		audio.acoustics = acoustics.New(
			audio,
			ground_tracer(
				{{55, 75, 0, 10, -10, 10}},
				0.1,
				{
					rays = 512,
					bounces = 8,
					samples = 128,
					sources = 1,
					fresnel = 2,
					reflection_sources = 1,
				}
			)
		)
		audio.SetListenerPosition(Vec3(15, 1.5, 0))
		local snd = mono_source(64, function()
			return 0
		end)
		snd:SetLooping(true)
		snd:SetPosition(Vec3(-15, 1.5, 0))
		snd:Play()

		for _ = 1, 90 do
			ctx.time = ctx.time + 1 / 60
			audio.Update()
		end

		local profile = audio.acoustics.profile
		T(profile.t60[2])["<"](0.5)
		T(audio.state.buses[0].t60[1])["<"](math.max(profile.t60[2] * 2, 0.6))
		audio.StopAll()
	end)
end)

T.Test("audio a far listener hears the reverb of the space the sound is in, from the sound's own trace", function()
	with_offline_mixer(function(ctx)
		audio.acoustics = acoustics.New(
			audio,
			ground_tracer(
				{
					{-42, 42, 0, 10, -42, -40},
					{-42, 42, 0, 10, 40, 42},
					{-42, -40, 0, 10, -40, 40},
				},
				0.1,
				{
					rays = 512,
					bounces = 8,
					samples = 128,
					sources = 1,
					fresnel = 2,
					reflection_sources = 1,
				}
			)
		)
		audio.SetListenerPosition(Vec3(300, 1.5, 0))
		local snd = mono_source(64, function()
			return 0
		end)
		snd:SetLooping(true)
		snd:SetReferenceDistance(1)
		snd:SetPosition(Vec3(-10, 1.5, 0))
		snd:Play()

		for _ = 1, 150 do
			ctx.time = ctx.time + 1 / 60
			audio.Update()
		end

		local env = snd.audio_environment
		local distance2 = 310 ^ 2
		local emitter = env.emitter
		T(emitter ~= nil and emitter.reverb ~= nil)["=="](true)
		T(math.abs(env.energy / emitter.reverb.energy[2] - 1))["<"](0.01)
		T(emitter.reverb.energy[2] * distance2)[">"](0.1)
		T(emitter.reverb.energy[2])[">"](1.2 * env.sums.late[2] / env.sums.rays)
		T(env.send[1] + env.send[2])[">"](0)
		audio.StopAll()
	end)
end)

T.TestPhysics("audio acoustics occludes a source behind a static wall", function()
	local Entity = import("goluwa/entities/entity.lua")
	local BoxShape = import("goluwa/physics/shapes/box.lua")
	local wall = Entity.New({Name = "acoustic_wall"})
	wall:AddComponent("transform")
	wall.transform:SetPosition(Vec3(0, 2, -5))
	wall:AddComponent("rigid_body", {Shape = BoxShape.New(Vec3(20, 4, 0.3)), MotionType = "static"})
	local tracer = acoustics_cpu.New()
	local listener = Vec3(0, 1.7, 0)
	local hidden = acoustics.FresnelProbe(tracer, listener, Vec3(0, 1.7, -10), audio.speed_of_sound, 8)
	local open = acoustics.FresnelProbe(tracer, listener, Vec3(0, 1.7, 4), audio.speed_of_sound, 8)

	for band = 1, 3 do
		T(hidden[band])["=="](0)
		T(open[band])["=="](1)
	end
end)

T.TestPhysics("audio acoustics lets sound through bodies that collide with nothing but not through a door", function()
	local Entity = import("goluwa/entities/entity.lua")
	local BoxShape = import("goluwa/physics/shapes/box.lua")
	local CapsuleShape = import("goluwa/physics/shapes/capsule.lua")
	local listener = Vec3(0, 1.7, 0)
	local source = Vec3(0, 1.7, -10)
	local tracer = acoustics_cpu.New()

	local function blocked()
		local through = acoustics.ProbeTransmission(tracer, listener, source, audio.speed_of_sound)
		return through.leaves > 0
	end

	local hitbox = Entity.New{
		transform = {Position = Vec3(0, 1.7, -5)},
		rigid_body = {Shape = CapsuleShape.New(0.3, 1.2), MotionType = "kinematic", CollisionMask = 0},
	}
	import("goluwa/physics.lua").Update(1 / 60)
	T(blocked())["=="](false)
	hitbox:Remove()
	local door = Entity.New{
		transform = {Position = Vec3(0, 1.7, -5)},
		rigid_body = {Shape = BoxShape.New(Vec3(2, 3, 0.1)), MotionType = "kinematic"},
	}
	import("goluwa/physics.lua").Update(1 / 60)
	T(blocked())["=="](true)
	door:Remove()
end)

T.Test("audio sounds ramp in and out instead of clicking on a non zero sample", function()
	with_offline_mixer(function(ctx)
		local frames = 4410
		local data = ffi.new("float[?]", frames)

		for i = 0, frames - 1 do
			data[i] = 0.8
		end

		local sound = audio.CreateSource{data = data, samples = frames, channels = 1, sample_rate = FS}
		sound:SetSpatial(false)
		sound:Play(0)
		local out = ctx.Render(0.2)
		T(math.abs(out[0]))["<"](0.01)
		T(math.abs(out[2 * 200] - 0.8))["<"](1e-4)
		T(math.abs(out[2 * (frames - 1)]))["<"](0.01)
		sound:SetFadeIn(0.02)
		sound:Play(0)
		out = ctx.Render(0.1)
		T(out[2 * 441])["<"](0.5)
		T(math.abs(out[2 * 1500] - 0.8))["<"](1e-4)
	end)
end)

T.Test("audio the ear takes a share of what is above the reference loudness, the lows first, slowly", function()
	local threshold = -18

	-- steady state change in level (dB) of a tone of the given rms level after 2 s, and the change 0.2 s after the tone stops (a second, quiet tone follows)
	local function reduction(frequency, rms_db)
		local ear = dsp.CreateEar(FS)
		local frames = FS * 3
		local out = ffi.new("float[?]", frames * 2)
		local amplitude = 10 ^ (rms_db / 20) * math.sqrt(2)

		for i = 0, frames - 1 do
			local t = i / FS
			out[i * 2] = (t < 2 and amplitude or 10 ^ (-45 / 20)) * math.sin(2 * math.pi * frequency * t)
			out[i * 2 + 1] = out[i * 2]
		end

		local reference = ffi.new("float[?]", frames * 2)
		ffi.copy(reference, out, frames * 8)

		for i = 0, frames - 1, 512 do
			dsp.ProcessEar(ear, out + i * 2, math.min(512, frames - i), threshold)
		end

		local function level(buffer, from, to)
			local sum = 0

			for i = math.floor(from * FS), math.floor(to * FS) - 1 do
				sum = sum + buffer[i * 2] ^ 2
			end

			return 10 * math.log10(sum / ((to - from) * FS) + 1e-12)
		end

		return level(reference, 1.5, 2) - level(out, 1.5, 2),
		level(reference, 2.1, 2.3) - level(out, 2.1, 2.3)
	end

	local quiet = reduction(200, -30)
	T(math.abs(quiet))["<"](0.3)
	T(math.abs((reduction(3000, -30))))["<"](0.3)
	local bass = reduction(60, -6)
	local high = reduction(3000, -6)
	-- 6 dB over the bass threshold (6 dB above the reflex one), three quarters of it
	T(math.abs(bass - 4.5))["<"](1.5)
	-- 12 dB over the reflex threshold, three quarters of it, 60% of that on the highs
	T(high)[">"](3)
	T(high)["<"](8)
	local _, after = reduction(60, -6)
	T(after)[">"](2)
end)

T.Test("audio the explosion model has the blast wave of its charge, no net pressure and a dry waveform", function()
	local overpressure, duration = explosion.GetBlast(1, 10)
	T(math.abs(overpressure - 10000) / 10000)["<"](0.1)
	T(duration)[">"](0.002)
	T(duration)["<"](0.006)
	local near = explosion.GetBlast(1, 20)
	local far = explosion.GetBlast(1, 200)
	T(near)["<"](overpressure)
	T(far)["<"](near / 5)
	local data, count, peak_pressure = explosion.Generate(0.05, 50, FS, 1)
	local peak, sum, minimum, early = 0, 0, 0, 0

	for i = 0, count - 1 do
		peak = math.max(peak, math.abs(data[i]))
		minimum = math.min(minimum, data[i])
		sum = sum + data[i]
	end

	for i = 3, 20 do
		early = math.max(early, data[i])
	end

	T(math.abs(peak - 1))["<"](1e-6)
	T(math.abs(sum / count))["<"](0.005)
	T(early)[">"](0.5)
	T(minimum)["<"](-0.05)
	T(peak_pressure)[">"](0)
end)

T.Test("audio levels are dB SPL and the limiter keeps the output under its ceiling", function()
	with_offline_mixer(function(ctx)
		local frames = 8820
		local data = ffi.new("float[?]", frames)

		for i = 0, frames - 1 do
			data[i] = 0.3 * math.sin(i * 2 * math.pi * 100 / FS)
		end

		local sound = audio.CreateSource{data = data, samples = frames, channels = 1, sample_rate = FS}
		sound:SetSpatial(false)
		sound:SetLevel(audio.reference_spl + 20)
		T(sound:GetVolume())["=="](10)
		T(sound:GetLevel())["=="](audio.reference_spl + 20)
		sound:Play(0)
		local out = ctx.Render(0.25)
		local peak = 0

		for i = 0, frames * 2 - 1 do
			peak = math.max(peak, math.abs(out[i]))
		end

		T(peak)["<="](dsp.LIMITER_CEILING + 1e-5)
		T(peak)[">"](dsp.LIMITER_CEILING * 0.95)
		T(audio.state.debug_limiter_gain)["<"](0.5)
	end)
end)

T.Test("audio fade in fraction spreads the ramp over the whole sound", function()
	with_offline_mixer(function(ctx)
		local frames = 4410
		local data = ffi.new("float[?]", frames)

		for i = 0, frames - 1 do
			data[i] = 0.8
		end

		local sound = audio.CreateSource{data = data, samples = frames, channels = 1, sample_rate = FS}
		sound:SetSpatial(false)
		sound:SetFadeInFraction(1)
		sound:Play(0)
		local out = ctx.Render(0.1)
		T(math.abs(out[2 * math.floor(frames / 2)] - 0.4))["<"](0.02)
		T(out[2 * (frames - 300)])[">"](0.7)
	end)
end)

local function transmission_db(out, band)
	return -10 * math.log10(out[band])
end

T.Test("audio wall transmission follows the mass law for one and two leaves", function()
	local single, double, normal, field = {}, {}, {}, {}
	acoustics.ChainTransmission(1, {10}, {1}, {0}, 343, single)
	acoustics.ChainTransmission(1, {20}, {1}, {0}, 343, double)

	for band = 1, 3 do
		local step = transmission_db(double, band) - transmission_db(single, band)
		T(step)[">="](5)
		T(step)["<="](6.1)
	end

	acoustics.ChainTransmission(1, {100}, {1}, {0}, 343, normal)
	acoustics.ChainTransmission(1, {100}, {1}, {0}, 343, field, true)

	for band = 1, 3 do
		local drop = transmission_db(normal, band) - transmission_db(field, band)
		T(drop)[">="](3)
		T(drop)["<="](6)
	end

	local leaves, combined = {}, {}
	acoustics.ChainTransmission(2, {10, 10}, {1, 1}, {0, 0.1}, 343, leaves)
	acoustics.ChainTransmission(1, {20}, {1}, {0}, 343, combined)

	for band = 1, 3 do
		T(transmission_db(leaves, band))[">="](transmission_db(combined, band) - 1e-6)
	end

	local expected = 0

	for k = 7, 9 do
		expected = expected + acoustics.LimpTransmission(acoustics.BAND_FREQUENCIES[k], 10, 1) ^ 2 / 4 / 3
	end

	T(math.abs(transmission_db(leaves, 3) + 10 * math.log10(expected)))["<="](0.01)
end)

T.TestPhysics("audio transmission measures walls on the physics tracer", function()
	local Entity = import("goluwa/entities/entity.lua")
	local BoxShape = import("goluwa/physics/shapes/box.lua")
	local MeshShape = import("goluwa/physics/shapes/mesh.lua")
	local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
	local physics = import("goluwa/physics.lua")
	local tracer = acoustics_cpu.New()
	local default = acoustics.DEFAULT_MATERIAL
	local wall = Entity.New({Name = "transmission_wall"})
	wall:AddComponent("transform")
	wall.transform:SetPosition(Vec3(0, 2, -5))
	wall:AddComponent("rigid_body", {Shape = BoxShape.New(Vec3(20, 4, 0.3)), MotionType = "static"})
	local through = acoustics.ProbeTransmission(tracer, Vec3(0, 1.7, 0), Vec3(0, 1.7, -10), audio.speed_of_sound)
	local expected = acoustics.ChainTransmission(1, {default.density * 0.3}, {1}, {0}, audio.speed_of_sound, {})
	T(through.solid)["~"](0.3, 1e-3)
	T(through.leaves)["=="](1)

	for band = 1, 3 do
		T(math.abs(transmission_db(through, band) - transmission_db(expected, band)))["<="](0.01)
	end

	wall:Remove()

	local function mesh_owner(primitive)
		local owner = Entity.New{Name = "transmission_mesh", transform = {Position = Vec3(0, 2, -5)}}
		owner:AddComponent(
			"rigid_body",
			{
				Shape = MeshShape.New{Model = {Primitives = {primitive}}},
				MotionType = "static",
			}
		)
		physics.Update(1 / 60)
		return owner
	end

	local brush = mesh_owner{
		brush_planes = {
			{normal = Vec3(1, 0, 0), dist = 10},
			{normal = Vec3(-1, 0, 0), dist = 10},
			{normal = Vec3(0, 1, 0), dist = 2},
			{normal = Vec3(0, -1, 0), dist = 2},
			{normal = Vec3(0, 0, 1), dist = 0.2},
			{normal = Vec3(0, 0, -1), dist = 0.2},
		},
	}
	local brush_through = acoustics.ProbeTransmission(tracer, Vec3(0, 1.7, 0), Vec3(0, 1.7, -10), audio.speed_of_sound)
	T(brush_through.solid)["~"](0.4, 1e-3)
	T(brush_through.leaves)["=="](1)
	brush:Remove()
	local poly = Polygon3D.New()

	for _, v in ipairs{
		Vec3(-5, -2, 0),
		Vec3(5, -2, 0),
		Vec3(-5, 2, 0),
		Vec3(5, -2, 0),
		Vec3(5, 2, 0),
		Vec3(-5, 2, 0),
	} do
		poly:AddVertex({pos = v})
	end

	poly:BuildBoundingBox()
	mesh_owner{polygon3d = poly}
	local flat = acoustics.ProbeTransmission(tracer, Vec3(0, 1.7, 0), Vec3(0, 1.7, -10), audio.speed_of_sound)
	local flat_expected = acoustics.ChainTransmission(1, {default.surface_mass}, {1}, {0}, audio.speed_of_sound, {})
	T(flat.solid)["=="](0)
	T(flat.leaves)["=="](1)

	for band = 1, 3 do
		T(math.abs(transmission_db(flat, band) - transmission_db(flat_expected, band)))["<="](0.01)
	end
end)

local function rain_room(hole_width)
	local W, H, D, alpha = 6, 3, 5, 0.2
	local material = acoustics.NewMaterial({alpha, alpha, alpha}, {1, 1, 1}, 1e6, 1e6, {0, 0, 0}, {0, 0, 0})
	return box_tracer(
		Vec3(-W / 2, 0, -D / 2),
		Vec3(W / 2, H, D / 2),
		alpha,
		{
			rays = 512,
			bounces = 12,
			samples = 128,
			sources = 1,
			fresnel = 2,
			reflection_sources = 1,
		},
		false,
		material,
		function(x, y, z, nx)
			return nx == -1 and math.abs(y - 1.5) <= 0.5 and math.abs(z) <= hole_width / 2
		end
	),
	W,
	H,
	D,
	alpha
end

local function gather_rain(hole_width, ctx)
	local tracer, W, H, D, alpha = rain_room(hole_width)
	audio.acoustics = acoustics.New(audio, tracer)
	audio.SetListenerPosition(Vec3(0, 1.5, 0))
	audio.SetAmbienceTracing(Vec3(0, 1, 0), nil)

	for _ = 1, 60 do
		ctx.time = ctx.time + 1 / 60
		audio.Update()
	end

	audio.StopAmbienceTracing()
	local S = 2 * (W * H + W * D + H * D) - hole_width
	local far = acoustics.DEFAULT_MATERIAL.rain[2]
	local reverberant = far * 0.5 * hole_width / (alpha * S / (1 - alpha) + hole_width)
	local w, h, d = hole_width / 2, 0.5, W / 2
	local solid_angle = 4 * math.asin(w * h / math.sqrt((w * w + d * d) * (h * h + d * d)))
	return audio.acoustics:GetAmbience(),
	reverberant + far * 0.5 * solid_angle / (4 * math.pi)
end

T.Test("audio ambience through an opening matches the diffuse field and comes from the opening", function()
	with_offline_mixer(function(ctx)
		local small, small_expected = gather_rain(1, ctx)
		T(math.abs(small.rain[2] - small_expected) / small_expected)["<="](0.25)
		local strongest = small.bins[1]
		T(strongest.direction.x)[">"](0.7)
		local large, large_expected = gather_rain(2, ctx)
		T(math.abs(large.rain[2] - large_expected) / large_expected)["<="](0.25)
		T(large.rain[2] / small.rain[2])[">"](1.5)
	end)
end)

T.Test("audio acoustics per band scattering keeps the decay of each band", function()
	with_offline_mixer(function(ctx)
		local W, H, D, alpha = 10, 4, 8, 0.1
		audio.acoustics = acoustics.New(
			audio,
			box_tracer(
				Vec3(-W / 2, 0, -D / 2),
				Vec3(W / 2, H, D / 2),
				alpha,
				{
					rays = 256,
					bounces = 10,
					samples = 128,
					sources = 1,
					fresnel = 2,
					reflection_sources = 1,
				},
				false,
				box_material(alpha, {0.05, 0.5, 0.95})
			)
		)
		audio.SetListenerPosition(Vec3(1.3, 1.7, 0.6))

		for _ = 1, 40 do
			ctx.time = ctx.time + 1 / 60
			audio.Update()
		end

		local V = W * H * D
		local S = 2 * (W * H + W * D + H * D)

		for band = 1, 3 do
			local eyring = 0.161 * V / (
					-S * math.log(1 - alpha) + 4 * acoustics.AirEnergyPerMeter(band) * V
				)
			T(math.abs(audio.acoustics.profile.t60[band] - eyring) / eyring)["<="](0.1)
		end
	end)
end)

T.Test("audio scattering scale multiplies every material's scattering in the trace", function()
	local function reflected_scattering(scale)
		local result
		local saved = acoustics.scattering_scale
		acoustics.scattering_scale = scale

		with_offline_mixer(function(ctx)
			audio.acoustics = acoustics.New(
				audio,
				box_tracer(
					Vec3(-5, 0, -4),
					Vec3(5, 4, 4),
					0.1,
					{
						rays = 256,
						bounces = 4,
						samples = 128,
						sources = 1,
						fresnel = 2,
						reflection_sources = 1,
					},
					false,
					box_material(0.1, {0.1, 0.1, 0.1})
				)
			)
			audio.SetListenerPosition(Vec3(1, 1.7, 0.5))

			for _ = 1, 40 do
				ctx.time = ctx.time + 1 / 60
				audio.Update()
			end

			local reflector = audio.acoustics:GetTopReflectors()[1]
			result = reflector.scattering[2] / reflector.count
		end)

		acoustics.scattering_scale = saved
		return result
	end

	T(reflected_scattering(1))["~"](0.1, 0.02)
	T(reflected_scattering(3))["~"](0.3, 0.03)
	T(reflected_scattering(20))["~"](1, 0.001)
end)

T.Test("audio acoustics clusters nearby sounds onto one traced source", function()
	with_offline_mixer(function(ctx)
		audio.acoustics = acoustics.New(
			audio,
			box_tracer(
				Vec3(-5, 0, -4),
				Vec3(5, 4, 4),
				0.1,
				{
					rays = 256,
					bounces = 10,
					samples = 128,
					sources = 1,
					fresnel = 2,
					reflection_sources = 1,
				}
			)
		)
		audio.SetListenerPosition(Vec3(1.3, 1.7, 0.6))
		local a = mono_source(64, function()
			return 0
		end)
		local b = mono_source(64, function()
			return 0
		end)

		for _, snd in ipairs{a, b} do
			snd:SetLooping(true)
		end

		a:SetPosition(Vec3(-2.5, 1.2, -1.1))
		b:SetPosition(Vec3(-2.0, 1.2, -0.6))
		a:Play()
		b:Play()

		for _ = 1, 40 do
			ctx.time = ctx.time + 1 / 60
			audio.Update()
		end

		T(a.audio_environment.sums.rays)[">"](0)
		T(b.audio_environment.sums.rays)[">"](0)
		T(math.abs(b.audio_environment.send[1] / a.audio_environment.send[1] - 1))["<="](0.2)
		audio.StopAll()
	end)
end)

local function band_power(out, from, count, frequency, size)
	size = size or 8192
	local window = {}
	local window_energy = 0

	for n = 0, size - 1 do
		local x = 2 * math.pi * n / (size - 1)
		window[n] = 0.35875 - 0.48829 * math.cos(x) + 0.14128 * math.cos(2 * x) - 0.01168 * math.cos(3 * x)
		window_energy = window_energy + window[n] ^ 2
	end

	local w = 2 * math.pi * frequency / FS
	local coefficient = 2 * math.cos(w)
	local total, segments = 0, 0

	for at = from, from + count - size, size do
		local s1, s2 = 0, 0

		for n = 0, size - 1 do
			local s0 = out[(at + n) * 2] * window[n] + coefficient * s1 - s2
			s2, s1 = s1, s0
		end

		total = total + (s1 * s1 + s2 * s2 - coefficient * s1 * s2) / window_energy
		segments = segments + 1
	end

	return total / segments
end

T.Test("audio reverb loop loses each high frequency at the rate air takes it", function()
	local reverb = dsp.CreateReverb(FS)
	local frames = FS * 2
	local input = ffi.new("float[?]", frames)
	local out = ffi.new("float[?]", frames * 2)
	math.randomseed(2)

	for i = 0, 43 do
		input[500 + i] = math.random() * 2 - 1
	end

	for i = 0, frames - 1, 512 do
		for j = 0, dsp.REVERB_LINES - 1 do
			spatial.GetAirFilter(reverb.delay[j] / FS * audio.speed_of_sound, FS, reverb.air_coefficient, j * 6 - 1)
		end

		dsp.ProcessReverb(
			reverb,
			input + i,
			out + i * 2,
			math.min(512, frames - i),
			FS,
			12,
			12,
			12,
			0.02,
			2,
			1,
			0,
			1,
			1,
			0,
			0
		)
	end

	local size = 2048

	for _, f in ipairs{8000, 12500} do
		local levels = {}

		for at = 0, frames - size, 512 do
			levels[#levels + 1] = {
				t = (at + size / 2) / FS,
				db = 10 * math.log10(band_power(out, at, size, f, size) + 1e-30),
			}
		end

		local peak, peak_at = -1e9, 1

		for i, p in ipairs(levels) do
			if p.db > peak then peak, peak_at = p.db, i end
		end

		local n, sx, sy, sxx, sxy = 0, 0, 0, 0, 0

		for i = peak_at, #levels do
			local p = levels[i]

			if p.db < peak - 3 and p.db > peak - 40 then
				n, sx, sy, sxx, sxy = n + 1, sx + p.t, sy + p.db, sxx + p.t * p.t, sxy + p.t * p.db
			end
		end

		local rate = -(n * sxy - sx * sy) / (n * sxx - sx * sx)
		local expected = spatial.AirAbsorptionAt(f, 20, 0.5, 101325) * audio.speed_of_sound
		T(math.abs(rate / expected - 1))["<"](0.15)
	end
end)

T.Test("audio a long reflection loses each frequency the way ISO 9613-1 says", function()
	local frequencies = {2000, 4000, 8000}

	local function tap_spectrum(path)
		local result

		with_offline_mixer(function(ctx)
			local count = math.floor(0.1 * FS)
			math.randomseed(4)
			local noise = mono_source(count, function()
				return math.random() * 2 - 1
			end)
			noise:SetPosition(Vec3(0, 0, -2))
			noise:SetVolume(0.0001)
			local air = {}
			spatial.GetAirFilter(path, FS, air, 0)
			local delay = path / audio.speed_of_sound
			noise.audio_environment = {
				taps = {
					{
						delay_left = delay,
						delay_right = delay,
						rate_left = 0,
						rate_right = 0,
						height = 0,
						front = 1,
						gain_left = 1 / path,
						gain_right = 1 / path,
						air = air,
					},
				},
				tap_band = {1, 1, 1},
				send = {0, 0},
			}
			noise:Play()
			local out = ctx.Render(delay + 0.2)
			result = {}

			for i, f in ipairs(frequencies) do
				result[i] = band_power(out, math.floor((delay + 0.02) * FS), math.floor(0.06 * FS), f, 2048)
			end
		end)

		return result
	end

	local near, far = tap_spectrum(50), tap_spectrum(150)

	for i, f in ipairs(frequencies) do
		local measured = 10 * math.log10(far[i] / near[i])
		local expected = 20 * math.log10(50 / 150) - spatial.AirAbsorptionAt(f, 20, 0.5, 101325) * 100
		T(math.abs(measured - expected))["<"](3)
	end
end)

local function ground_effect_levels(distance, source_height, listener_height, frequencies)
	local function spectrum(with_acoustics)
		local result

		with_offline_mixer(function(ctx)
			audio.SetListenerPosition(Vec3(distance, listener_height, 0))
			audio.SetListenerOrientation(Vec3(-1, 0, 0), Vec3(0, 1, 0))

			if with_acoustics then
				audio.acoustics = acoustics.New(
					audio,
					ground_tracer(
						{},
						0.6,
						{
							rays = 512,
							bounces = 4,
							samples = 128,
							sources = 1,
							fresnel = 2,
							reflection_sources = 1,
						},
						{0, 0, 0}
					)
				)
				local keep = mono_source(64, function()
					return 0
				end)
				keep:SetLooping(true)
				keep:SetPosition(Vec3(0, source_height, 0))
				keep:Play()

				for _ = 1, 120 do
					ctx.time = ctx.time + 1 / 60
					audio.Update()
				end
			end

			math.randomseed(5)
			local burst = mono_source(math.floor(0.6 * FS), function()
				return math.random() * 2 - 1
			end)
			burst:SetReferenceDistance(1)
			burst:SetVolume(0.01)
			burst:SetPosition(Vec3(0, source_height, 0))
			burst:Play()
			local delay = math.sqrt(distance ^ 2 + (source_height - listener_height) ^ 2) / audio.speed_of_sound
			local out = ctx.Render(delay + 0.9)
			result = {}

			for i, f in ipairs(frequencies) do
				result[i] = band_power(out, math.floor((delay + 0.15) * FS), 6 * 4096, f, 4096)
			end

			audio.StopAll()
		end)

		return result
	end

	local free, engine = spectrum(false), spectrum(true)
	local result = {}

	for i, f in ipairs(frequencies) do
		local r1 = math.sqrt(distance ^ 2 + (source_height - listener_height) ^ 2)
		local r2 = math.sqrt(distance ^ 2 + (source_height + listener_height) ^ 2)
		local qr, qi = ground.Coefficient(f, ground.Resistivity(0.6), r2, (source_height + listener_height) / r2)
		local k = 2 * math.pi * f / audio.speed_of_sound
		local er, ei = math.cos(k * (r2 - r1)), math.sin(k * (r2 - r1))
		local a = r1 / r2
		local re, im = 1 + a * (qr * er - qi * ei), a * (qr * ei + qi * er)
		result[i] = {
			engine = 10 * math.log10(engine[i] / free[i]),
			exact = 10 * math.log10(re * re + im * im + 1e-12),
		}
	end

	return result
end

T.Test("audio ground effect: a distant source on the ground loses its low and mid frequencies like soft ground does", function()
	local levels = ground_effect_levels(400, 1.5, 1.7, {250, 400, 630, 1000, 1600, 2500})

	for _, level in ipairs(levels) do
		T(level.exact)["<"](-4)
		T(math.abs(level.engine - level.exact))["<"](4)
	end
end)

T.Test("audio ground effect: the reflection of an airburst arrives with the sign and phase of the ground", function()
	local levels = ground_effect_levels(1000, 100, 1.7, {160, 250, 400, 630, 1000, 1600, 2500})
	local sum = 0

	for _, level in ipairs(levels) do
		local difference = math.abs(level.engine - level.exact)
		T(difference)["<"](4)
		sum = sum + difference
	end

	T(sum / #levels)["<"](1.5)
end)

T.Test("audio distant sounds lose each frequency the way ISO 9613-1 says, not one flat band", function()
	local function spectrum(distance, frequencies)
		local result

		with_offline_mixer(function(ctx)
			local count = FS * 2
			math.randomseed(3)
			local noise = mono_source(count, function()
				return math.random() * 2 - 1
			end)
			noise:SetReferenceDistance(1)
			noise:SetVolume(0.001)
			noise:SetPosition(Vec3(0, 0, -distance))
			noise:Play()
			local delay = distance / audio.speed_of_sound
			local out = ctx.Render(delay + 1.6)
			local from = math.floor((delay + 0.3) * FS)
			result = {}

			for i, f in ipairs(frequencies) do
				result[i] = band_power(out, from, math.floor(1.3 * FS), f)
			end
		end)

		return result
	end

	local frequencies = {1000, 2000, 4000, 8000}
	local near = spectrum(2, frequencies)
	local far = spectrum(150, frequencies)

	for i, f in ipairs(frequencies) do
		local measured = 10 * math.log10(far[i] / near[i])
		local expected = 20 * math.log10(2 / 150) - spatial.AirAbsorptionAt(f, 20, 0.5, 101325) * 148
		T(math.abs(measured - expected))["<"](3)
	end
end)

T.Test("audio air absorption follows ISO 9613-1 and the speed of sound the temperature", function()
	T(spatial.AirAbsorptionAt(1000, 20, 0.5, 101325) * 1000)["~"](4.66, 0.15)
	T(spatial.AirAbsorptionAt(4000, 20, 0.5, 101325) * 1000)["~"](29.7, 0.9)
	T(spatial.AirAbsorptionAt(8000, 20, 0.5, 101325) * 1000)["~"](105, 3)
	local speed, absorption, subbands = audio.speed_of_sound, {unpack(spatial.AIR_ABSORPTION_DB)}, spatial.AIR_SUBBANDS
	audio.SetAir(0, 0.3, 101325)
	T(audio.speed_of_sound)["~"](331.3, 1e-6)
	T(spatial.AIR_ABSORPTION_DB[3])[">"](absorption[2])
	audio.SetSpeedOfSound(speed)

	for band = 1, 3 do
		spatial.AIR_ABSORPTION_DB[band] = absorption[band]
	end

	spatial.AIR_SUBBANDS = subbands
	local far = -20 * math.log10(spatial.AirAbsorption(3, 1000))
	T(far)["<"](spatial.AIR_ABSORPTION_DB[3] * 1000 * 0.5)
	T(far)[">"](spatial.AIR_SUBBANDS[3][1] * 1000)
end)

T.Test("audio refraction leaves a shadow zone upwind of a distant source and carries the sound downwind", function()
	local function level(wind)
		local result

		with_offline_mixer(function(ctx)
			local distance = 800
			spatial.WIND_GRADIENT = 0.026
			audio.SetWind(Vec3(wind, 0, 0))
			audio.SetListenerPosition(Vec3(distance, 1.7, 0))
			audio.SetListenerOrientation(Vec3(-1, 0, 0), Vec3(0, 1, 0))
			audio.acoustics = acoustics.New(
				audio,
				ground_tracer(
					{},
					0.6,
					{
						rays = 512,
						bounces = 4,
						samples = 128,
						sources = 1,
						fresnel = 2,
						reflection_sources = 1,
					},
					{0, 0, 0}
				)
			)
			local keep = mono_source(64, function()
				return 0
			end)
			keep:SetLooping(true)
			keep:SetPosition(Vec3(0, 1.5, 0))
			keep:Play()

			for _ = 1, 120 do
				ctx.time = ctx.time + 1 / 60
				audio.Update()
			end

			local count = FS
			local tone = mono_source(count, function(i)
				return math.sin(2 * math.pi * 2500 * i / FS)
			end)
			tone:SetReferenceDistance(1)
			tone:SetVolume(0.01)
			tone:SetPosition(Vec3(0, 1.5, 0))
			tone:Play()
			local delay = distance / (audio.speed_of_sound + wind)
			local out = ctx.Render(delay + 0.9)
			result = band_power(out, math.floor((delay + 0.2) * FS), 4096, 2500, 4096)
			audio.StopAll()
			audio.SetWind(Vec3(0, 0, 0))
		end)

		return 10 * math.log10(result)
	end

	local calm = level(0)
	local upwind = level(-4)
	local downwind = level(4)
	T(upwind - calm)["<"](-12)
	T(upwind - calm)[">"](-spatial.SHADOW_FLOOR_DB - 4)
	T(downwind - calm)[">"](0)
	T(downwind - calm)["<"](spatial.DUCT_MAX_DB + 3)
end)

T.Test("audio refraction shadow grows with the cube root of frequency, past the horizon of the rays only", function()
	local gains = {}

	local function shadow(distance, gradient)
		return spatial.GetRefraction(audio, gradient, distance, 1.5, 1.7, {})
	end

	local radius = audio.speed_of_sound / 0.1
	local horizon = math.sqrt(2 * radius) * (math.sqrt(1.5) + math.sqrt(1.7))
	gains = shadow(horizon * 0.5, -0.1)
	T(gains[2])["~"](1, 0.03)
	gains = shadow(horizon * 1.5, -0.1)
	T(gains[2])["<"](10 ^ (-spatial.SHADOW_EDGE_DB * 0.9 / 20))
	T(gains[1])[">"](gains[2])
	T(gains[2])[">"](gains[3])
	gains = shadow(horizon * 100, -0.1)
	T(gains[2])["~"](10 ^ (-spatial.SHADOW_FLOOR_DB / 20), 1e-6)
	gains = shadow(horizon * 4, 0.1)
	T(gains[2])[">"](1)
	T(gains[2])["<="](10 ^ (spatial.DUCT_MAX_DB / 20) + 1e-6)
end)

T.Test("audio turbulence makes distant highs fluctuate with the depth it predicts and keeps the mean power", function()
	local function levels(mu2)
		local result = {}

		with_offline_mixer(function(ctx)
			audio.SetTurbulence(mu2)
			audio.SetWind(Vec3(0, 0, 5))
			local distance = 300
			local count = FS * 12
			local tone = mono_source(count, function(i)
				return math.sin(2 * math.pi * 8000 * i / FS)
			end)
			tone:SetReferenceDistance(1)
			tone:SetVolume(1)
			tone:SetPosition(Vec3(0, 0, -distance))
			tone:Play()
			local delay = distance / (audio.speed_of_sound + 5)
			local out = ctx.Render(delay + 10)
			local from = math.floor((delay + 0.5) * FS)

			for at = from, from + 9 * FS - 1024, 1024 do
				result[#result + 1] = band_power(out, at, 1024, 8000, 1024)
			end

			audio.StopAll()
			audio.SetWind(Vec3(0, 0, 0))
		end)

		return result
	end

	local mu2 = 3e-5
	local still, shaken = levels(0), levels(mu2)
	local mean_still, mean_shaken = 0, 0

	for i = 1, #still do
		mean_still = mean_still + still[i] / #still
		mean_shaken = mean_shaken + shaken[i] / #shaken
	end

	local mean_db, square = 0, 0

	for _, power in ipairs(shaken) do
		mean_db = mean_db + 10 * math.log10(power) / #shaken
	end

	for _, power in ipairs(shaken) do
		square = square + (10 * math.log10(power) - mean_db) ^ 2 / #shaken
	end

	local expected = 8.686 * spatial.ScintillationDepth(mu2, 6000, 300, audio.speed_of_sound)
	T(math.sqrt(square))[">"](expected * 0.55)
	T(math.sqrt(square))["<"](expected * 1.2)
	T(math.abs(10 * math.log10(mean_shaken / mean_still)))["<"](2.5)
end)

T.Test("audio turbulence scatters the ground reflection out of step with the direct sound at high frequencies and distance", function()
	local mu2 = 3e-6
	local c = audio.speed_of_sound
	T(spatial.Coherence(mu2, 250, 100, 1.5, c))[">"](0.97)
	T(spatial.Coherence(mu2, 8000, 100, 1.5, c))["<"](0.3)
	T(spatial.Coherence(mu2, 1500, 400, 1.5, c))["<"](spatial.Coherence(mu2, 1500, 100, 1.5, c))
	T(spatial.Coherence(mu2, 8000, 100, 0.01, c))[">"](0.99)
	T(spatial.ScintillationDepth(mu2, 6000, 5000, c))["~"](math.sqrt(spatial.SCINTILLATION_SATURATION), 0.03)
	T(spatial.ScintillationDepth(mu2, 6000, 10, c))["<"](spatial.ScintillationDepth(mu2, 6000, 300, c))
end)

T.Test("audio output modes: limiter keeps the ceiling, clip stops at full scale, soft saturates, gain comes before them", function()
	local function peak(mode, gain)
		local result

		with_offline_mixer(function(ctx)
			audio.state.output_mode = mode
			audio.state.output_gain = gain
			local tone = mono_source(FS, function(i)
				return math.sin(2 * math.pi * 440 * i / FS)
			end)
			tone:SetSpatial(false)
			tone:SetNormalized(false)
			tone:SetVolume(4)
			tone:Play()
			local out, total = ctx.Render(0.5)
			result = 0

			for i = 4000, total * 2 - 1 do
				result = math.max(result, math.abs(out[i]))
			end

			audio.StopAll()
		end)

		return result
	end

	T(peak(0, 1))["<="](dsp.LIMITER_CEILING + 1e-3)
	T(peak(1, 1))["~"](1, 1e-3)
	T(peak(2, 1))["<"](1)
	T(peak(2, 1))[">"](0.99)
	T(peak(1, 0.125))["~"](0.5, 0.02)
end)

T.Test("audio reverb onset delay stays within a couple of mean free paths of travel", function()
	local stats = acoustics.NewStats()
	stats.rays = 1000
	local sums = acoustics.NewSourceSums()
	sums.rays = 1000

	for b = 1, 3 do
		sums.late[b] = 1
		sums.moment[b] = 0.8
		sums.moment2[b] = 0.64
	end

	local profile = {
		mean_free_path = 35,
		predelay = 0.08,
		t60 = {2, 2, 1},
		tail_survival = {0.5, 0.5, 0.2},
		tail_path = {35, 35, 35},
	}
	local speed = 343.3
	local result = acoustics.ComputeSourceReverb(sums, stats, profile, 0, speed)
	T(result.delay)["~"](acoustics.MAX_TAIL_DELAY_PATHS * 35 / speed, 0.01)
end)

T.Test("audio remote reverb bus plays from its direction with the time difference between the ears", function()
	local frames = FS
	local reverb = dsp.CreateReverb(FS)
	local input = ffi.new("float[?]", frames)
	local out = ffi.new("float[?]", frames * 2)
	local seed = 3

	for i = 0, FS / 4 do
		seed = (seed * 1103515245 + 12345) % 2147483648
		input[i] = seed / 2147483648 - 0.5
	end

	local lag = 20

	for i = 0, frames - 1, 512 do
		dsp.ProcessReverb(
			reverb,
			input + i,
			out + i * 2,
			math.min(512, frames - i),
			FS,
			1,
			1,
			1,
			0.02,
			1,
			1,
			1,
			1.3,
			0.6,
			0,
			lag / FS
		)
	end

	local left, right = 0, 0

	for i = 0, frames - 1 do
		left = left + out[i * 2] ^ 2
		right = right + out[i * 2 + 1] ^ 2
	end

	T(10 * math.log10(left / right))["~"](20 * math.log10(1.3 / 0.6), 0.5)
	local best, best_lag = -math.huge, 0

	for k = 0, 40 do
		local sum = 0

		for i = 0, frames - 1 - k do
			sum = sum + out[i * 2] * out[(i + k) * 2 + 1]
		end

		if sum > best then best, best_lag = sum, k end
	end

	T(best_lag)["=="](lag)
end)

local function snow_t60(open_top, depth, ctx)
	audio.acoustics = acoustics.New(
		audio,
		box_tracer(
			Vec3(-6, 0, -5),
			Vec3(6, 6, 5),
			0.03,
			{
				rays = 512,
				bounces = 10,
				samples = 128,
				sources = 1,
				fresnel = 2,
				reflection_sources = 1,
			},
			open_top
		)
	)
	audio.SetListenerPosition(Vec3(1.3, 1.7, 0.6))
	audio.SetSnowDepth(depth)

	for _ = 1, 40 do
		ctx.time = ctx.time + 1 / 60
		audio.Update()
	end

	audio.SetSnowDepth(0)
	return {unpack(audio.acoustics.profile.t60)}
end

T.Test("audio snow covers only exposed ground and absorbs the bands its depth reaches", function()
	with_offline_mixer(function(ctx)
		local closed, closed_snow = snow_t60(false, 1, ctx), snow_t60(false, 1, ctx)
		local bare = snow_t60(true, 0, ctx)
		local snowed = snow_t60(true, 0.02, ctx)

		for band = 1, 3 do
			T(math.abs(closed_snow[band] / closed[band] - 1))["<="](0.05)
		end

		local low, mid, high = snowed[1] / bare[1], snowed[2] / bare[2], snowed[3] / bare[3]
		T(high)["<"](mid)
		T(mid)["<"](low)
		T(high)["<"](0.8)
	end)
end)

T.TestPhysics("audio diffraction around a wall edge follows the barrier loss of its shortest detour", function()
	local Entity = import("goluwa/entities/entity.lua")
	local BoxShape = import("goluwa/physics/shapes/box.lua")
	local physics = import("goluwa/physics.lua")
	local wall = Entity.New({Name = "diffraction_wall"})
	wall:AddComponent("transform")
	wall.transform:SetPosition(Vec3(0, 2, -5))
	wall:AddComponent("rigid_body", {Shape = BoxShape.New(Vec3(4, 4, 0.05)), MotionType = "static"})
	physics.Update(1 / 60)
	local tracer = acoustics_cpu.New()
	local listener, source = Vec3(0, 1.7, 0), Vec3(2.5, 1.7, -10)
	local edge = Vec3(2, 1.7, -5)
	local exact = (
			edge - listener
		):GetLength() + (
			source - edge
		):GetLength() - (
			source - listener
		):GetLength()
	local found = acoustics.DetourProbe(tracer, listener, source, 24)
	local expected, measured = {}, {}
	acoustics.DiffractionGain(exact, audio.speed_of_sound, expected)
	acoustics.DiffractionGain(found, audio.speed_of_sound, measured)
	T(found)[">="](exact - 0.01)

	for band = 1, 2 do
		T(math.abs(10 * math.log10(measured[band] / expected[band])))["<="](2)
	end

	T(10 * math.log10(acoustics.DiffractionGain(0, audio.speed_of_sound, {})[2]))["~"](-5, 0.01)
	T(acoustics.DiffractionGain(acoustics.DETOUR_NONE, audio.speed_of_sound, {})[2])["=="](0)
end)

local function exact_doppler(start, velocity, t, wind, c)
	local lo, hi = 0, 10

	for _ = 1, 200 do
		local tau = (lo + hi) / 2

		if (start + velocity * (t - tau) + wind * tau):GetLength() > c * tau then
			lo = tau
		else
			hi = tau
		end
	end

	local tau = (lo + hi) / 2
	local n = (start + velocity * (t - tau) + wind * tau):GetNormalized() * -1
	return 1000 * (c + n:GetDot(wind)) / (c - n:GetDot(velocity - wind))
end

T.Test("audio doppler stays exact for fast sources and in moving air", function()
	local c = audio.speed_of_sound

	local function measure(start, velocity, wind)
		local f

		with_offline_mixer(function(ctx)
			audio.SetWind(wind)
			local sine = mono_source(FS * 3, function(i)
				return math.sin(2 * math.pi * 1000 * i / FS) * 0.5
			end)
			sine:SetLooping(true)
			sine:SetPosition(start)
			sine:Play()
			local out = ctx.Render(2.2, function(t)
				sine:SetPosition(start + velocity * t)
			end)
			f = frequency(out, 0, math.floor(2.0 * FS), math.floor(2.1 * FS))
			audio.SetWind(Vec3(0, 0, 0))
		end)

		return f
	end

	for _, case in ipairs{
		{Vec3(20, 0, -350), Vec3(0, 0, 250), Vec3(0, 0, 0)},
		{Vec3(20, 0, -150), Vec3(0, 0, 100), Vec3(15, 0, 0)},
		{Vec3(0, 0, -100), Vec3(0, 0, 0), Vec3(0, 0, 10)},
	} do
		local expected = exact_doppler(case[1], case[2], 2.05, case[3], c)
		T(math.abs(measure(case[1], case[2], case[3]) / expected - 1))["<="](0.001)
	end
end)

T.Test("audio delay follows the wind along the path", function()
	local c = audio.speed_of_sound
	local count = math.floor(0.04 * FS)

	for _, wind in ipairs{Vec3(0, 0, 10), Vec3(0, 0, -10), Vec3(20, 0, 0)} do
		with_offline_mixer(function(ctx)
			audio.SetWind(wind)
			local burst = mono_source(count, function(i)
				local t = (i - count / 2) / FS
				return math.exp(-(t / 0.003) ^ 2) * math.cos(2 * math.pi * 2000 * t)
			end)
			burst:SetPosition(Vec3(0, 0, -100))
			burst:Play()
			local out, total = ctx.Render(0.5)
			local delay = (peak_index(out, total, 0) - count / 2) / FS
			audio.SetWind(Vec3(0, 0, 0))
			T(delay)["~"](100 / (math.sqrt(c * c - wind.x * wind.x) + wind.z), 0.0003)
		end)
	end
end)

T.Test("audio doppler stays smooth when positions arrive in physics steps between frames", function()
	local c = audio.speed_of_sound
	local speed = 5
	local expected = 1000 * (c + speed) / c
	local cents = {}

	with_offline_mixer(function(ctx)
		local sine = mono_source(FS * 2, function(i)
			return math.sin(2 * math.pi * 1000 * i / FS) * 0.5
		end)
		sine:SetLooping(true)
		sine:SetPosition(Vec3(0, 0, -50))
		sine:Play()
		local total = 3 * FS
		local out = ffi.new("float[?]", total * 2)
		local done, next_update = 0, 0

		while done < total do
			local frames = math.min(512, total - done)
			local now = ctx.mixer.frames_done / FS

			while now >= next_update do
				ctx.time = next_update
				audio.SetListenerPosition(Vec3(0, 0, -speed * math.floor(next_update * 60) / 60))
				audio.Update()
				next_update = next_update + 1 / 144
			end

			ctx.time = now
			mix.MixOutputBuffer(ctx.mixer, out + done * 2, frames * 2)
			done = done + frames
		end

		local previous
		local last = out[FS * 2]

		for i = FS + 1, total - 1 do
			local v = out[i * 2]

			if last < 0 and v >= 0 then
				local crossing = i - 1 + last / (last - v)

				if previous then
					cents[#cents + 1] = 1200 * math.log(FS / (crossing - previous) / expected) / math.log(2)
				end

				previous = crossing
			end

			last = v
		end
	end)

	local worst = 0

	for _, value in ipairs(cents) do
		worst = math.max(worst, math.abs(value))
	end

	T(#cents)[">"](1000)
	T(worst)["<"](3)
end)

T.Test("audio streams keep refilling what was played so they never repeat", function()
	with_offline_mixer(function(ctx)
		local counter = 0
		local stream = audio.CreateStream(
			function(data, from, count)
				for i = from, from + count - 1 do
					data[i] = counter / 200000
					counter = counter + 1
				end
			end,
			0.25,
			FS,
			1
		)
		stream:SetSpatial(false)
		stream:Play()
		local out, total = ctx.Render(3)
		local drops = 0

		for i = math.floor(0.1 * FS), total - 1 do
			if out[i * 2] < out[(i - 1) * 2] - 1e-4 then drops = drops + 1 end
		end

		T(drops)["=="](0)
		T(out[(total - 1) * 2])[">"](out[math.floor(1.5 * FS) * 2])
		stream:Cut()
	end)
end)
