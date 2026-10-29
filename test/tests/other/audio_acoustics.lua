local T = import("test/environment.lua")
local ffi = require("ffi")
local audio = import("goluwa/audio.lua")
local mix = import("goluwa/audio/mix.lua")
local dsp = import("goluwa/audio/dsp.lua")
local acoustics = import("goluwa/audio/acoustics.lua")
local acoustics_cpu = import("goluwa/audio/acoustics_cpu.lua")
local spatial = import("goluwa/audio/spatial.lua")
local pvars = import("goluwa/cli/pvars.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local FS = 44100

local function with_offline_mixer(cb)
	local saved_state, saved_sounds, saved_clock, saved_motion = audio.state, audio.active_sounds, audio.clock, audio.listener_motion
	local saved_acoustics = audio.acoustics
	local saved_position, saved_forward, saved_up = audio.listener_position, audio.listener_forward, audio.listener_up
	local ctx = {time = 0}
	audio.state = audio.CreateMixerState()
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
	audio.acoustics = saved_acoustics
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
				1
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
			diffusion
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

local function box_tracer(min, max, absorption, budget, open_top)
	local tracer = acoustics_cpu.New(budget)
	local a = {absorption, absorption, absorption}

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
