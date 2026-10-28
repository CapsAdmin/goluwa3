local T = import("test/environment.lua")
local ffi = require("ffi")
local audio = import("goluwa/audio.lua")
local mix = import("goluwa/audio/mix.lua")
local dsp = import("goluwa/audio/dsp.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local FS = 44100

local function with_offline_mixer(cb)
	local saved_state, saved_sounds, saved_clock, saved_motion = audio.state, audio.active_sounds, audio.clock, audio.listener_motion
	local saved_position, saved_forward, saved_up = audio.listener_position, audio.listener_forward, audio.listener_up
	local ctx = {time = 0}
	audio.state = audio.CreateMixerState()
	audio.active_sounds = {}
	audio.listener_motion = {}
	audio.clock = function()
		return ctx.time
	end
	ctx.mixer = mix.CreateMixer(audio.state, FS, 512)
	ctx.mixer.clock = audio.clock
	audio.SetListenerPosition(Vec3(0, 0, 0))
	audio.SetListenerOrientation(Vec3(0, 0, -1), Vec3(0, 1, 0))

	function ctx.Render(seconds, on_frame)
		local total = math.floor(seconds * FS)
		local out = ffi.new("float[?]", total * 2)
		local done = 0
		local next_update = 0

		while done < total do
			local frames = math.min(512, total - done)
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

		return out, total
	end

	local ok, err = pcall(cb, ctx)
	audio.state, audio.active_sounds, audio.clock, audio.listener_motion = saved_state, saved_sounds, saved_clock, saved_motion
	audio.listener_position, audio.listener_forward, audio.listener_up = saved_position, saved_forward, saved_up

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

T.Test("audio propagation delay and interaural time difference", function()
	with_offline_mixer(function(ctx)
		local front = mono_source(64, function(i)
			return i == 0 and 1 or 0
		end)
		front:SetPosition(Vec3(0, 0, -34.33))
		front:Play()
		local out, total = ctx.Render(0.2)
		T(math.abs(peak_index(out, total, 0) - 34.33 / audio.speed_of_sound * FS))["<="](2)
		T(math.abs(peak_index(out, total, 0) - peak_index(out, total, 1)))["<="](1)
		audio.StopAll()
		local right = mono_source(64, function(i)
			return i == 0 and 1 or 0
		end)
		right:SetPosition(Vec3(3, 0, 0))
		right:Play()
		out, total = ctx.Render(0.1)
		local itd = (peak_index(out, total, 0) - peak_index(out, total, 1)) / FS
		T(math.abs(itd - audio.ear_distance / audio.speed_of_sound))["<="](0.00005)
	end)
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
				0.03
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
