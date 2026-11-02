local ffi = require("ffi")
local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local audio = import("goluwa/audio.lua")
local acoustics = import("goluwa/audio/acoustics.lua")
local spatial = import("goluwa/audio/spatial.lua")
local signals = import("goluwa/audio/signals.lua")
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local commands = import("goluwa/cli/commands.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local debug_draw = import("goluwa/debug_draw.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local SAMPLE_RATE = 48000
local EYE = 1.7
local previous = _G.audio_showcase

if previous then
	event.RemoveListener("Update", "audio_showcase")
	event.RemoveListener("Draw2D", "audio_showcase")

	for _, sound in ipairs(previous.sounds) do
		sound:Cut()
	end

	for _, ent in ipairs(previous.entities) do
		if ent:IsValid() then ent:Remove() end
	end
end

local showcase = {entities = {}, sounds = {}, scenes = {}}
_G.audio_showcase = showcase

local function add(ent)
	showcase.entities[#showcase.entities + 1] = ent
	return ent
end

local function material(color, absorption, scattering, density, surface_mass)
	return shapes.Material{
		Color = color,
		Roughness = 0.9,
		Metallic = 0,
		AcousticAbsorption = Vec3(absorption[1], absorption[2], absorption[3]),
		AcousticScattering = Vec3(scattering[1], scattering[2], scattering[3]),
		AcousticDensity = density,
		AcousticSurfaceMass = surface_mass,
	}
end

local MATERIALS = {
	grass = material(Color(0.26, 0.42, 0.16, 1), {0.2, 0.6, 0.8}, {0.1, 0.3, 0.6}, 1600, 160),
	asphalt = material(Color(0.12, 0.12, 0.13, 1), {0.03, 0.04, 0.06}, {0.05, 0.1, 0.2}, 2300, 230),
	rock = material(Color(0.5, 0.42, 0.34, 1), {0.02, 0.03, 0.05}, {0.1, 0.3, 0.5}, 2600, 260),
	concrete = material(Color(0.6, 0.6, 0.6, 1), {0.02, 0.03, 0.04}, {0.05, 0.1, 0.15}, 2300, 230),
	wood = material(Color(0.5, 0.35, 0.2, 1), {0.12, 0.08, 0.08}, {0.05, 0.1, 0.15}, 600, 12),
	metal = material(Color(0.55, 0.57, 0.6, 1), {0.02, 0.02, 0.03}, {0.05, 0.05, 0.1}, 300, 15),
}
local MARKERS = {
	car = shapes.Material{Color = Color(0.9, 0.1, 0.1, 1), Roughness = 0.4, Metallic = 0},
	source = shapes.Material{Color = Color(1, 0.8, 0.2, 1), Roughness = 0.4, Metallic = 0},
	ambulance = shapes.Material{Color = Color(0.95, 0.95, 0.95, 1), Roughness = 0.5, Metallic = 0},
}

local function box(name, position, size, mat, rotation)
	return add(
		shapes.Box{
			Name = "audio_showcase " .. name,
			Position = position,
			Size = size,
			Rotation = rotation,
			Material = mat,
			RigidBody = {MotionType = "static"},
		}
	)
end

-- markers stay out of the traced scene: a clap source in line with a cliff would otherwise hide that cliff's echo
local function marker(name, position, mat, size)
	local ent = add(
		shapes.Box{
			Name = "audio_showcase " .. name,
			Position = position,
			Size = size or Vec3(0.5, 0.5, 0.5),
			Material = mat,
			Collision = false,
		}
	)
	ent.visual:SetInSceneBVH(false)
	return ent
end

local function looping_source(samples, frames, volume)
	local sound = audio.CreateSource{data = samples, samples = frames, channels = 1, sample_rate = SAMPLE_RATE}
	sound:SetNormalized(true)
	sound:SetReferenceDistance(2)
	sound:SetLooping(true)
	sound:SetGain(volume)
	showcase.sounds[#showcase.sounds + 1] = sound
	return sound
end

local function one_shot_source(samples, frames, sample_rate, volume)
	local sound = audio.CreateSource{data = samples, samples = frames, channels = 1, sample_rate = sample_rate}
	sound:SetNormalized(true)
	sound:SetReferenceDistance(2)
	sound:SetGain(volume)
	showcase.sounds[#showcase.sounds + 1] = sound
	return sound
end

local function normalize(samples, frames)
	local peak = 0

	for i = 0, frames - 1 do
		peak = math.max(peak, math.abs(samples[i]))
	end

	for i = 0, frames - 1 do
		samples[i] = samples[i] * 0.9 / peak
	end
end

-- noise that loops without a step: the last stretch is crossfaded into the start
local function looping_noise(frames, seed)
	local overlap = math.floor(SAMPLE_RATE * 0.02)
	local raw = ffi.new("float[?]", frames + 2 * overlap)

	for i = 0, frames + 2 * overlap - 1 do
		seed = (seed * 1103515245 + 12345) % 2147483648
		raw[i] = seed / 1073741824 - 1
	end

	local out = ffi.new("float[?]", frames)

	for i = 0, frames - 1 do
		out[i] = raw[i + overlap]
	end

	for i = 0, overlap - 1 do
		local a = i / overlap
		out[i] = raw[i + overlap] * a + raw[i + frames + overlap] * (1 - a)
	end

	return out
end

local function lowpass(samples, frames, frequency)
	local k = 1 - math.exp(-2 * math.pi * frequency / SAMPLE_RATE)
	local y = 0

	for _ = 1, 2 do
		for i = 0, frames - 1 do
			y = y + (samples[i] - y) * k
			samples[i] = y
		end
	end
end

do
	-- the track: two straights joined by half circles, the car runs it with a speed and gear model
	local ORIGIN = Vec3(0, 0, 0)
	local STRAIGHT = 700
	local RADIUS = 120
	local CORNER_SPEED = math.sqrt(30 * RADIUS)
	local TOP_SPEED = 95
	local LAUNCH = 13
	local BRAKE = 45
	local REDLINE = 12000
	local UPSHIFT = 11700
	local DOWNSHIFT = 9300
	local GEARS = 8
	local FIRST_GEAR_SPEED = 27
	local GEAR_STEP = 1.2
	-- 167 revolutions per second: every half order completes in the 2 s loop
	local REV = 167
	local LOOP_SECONDS = 2
	local LENGTH = 2 * STRAIGHT + 2 * math.pi * RADIUS
	local frames = SAMPLE_RATE * LOOP_SECONDS
	local engine = ffi.new("float[?]", frames)
	local rasp = looping_noise(frames, 17)
	lowpass(rasp, frames, 5000)
	local seed = 5
	local orders = {}

	for k = 1, 48 do
		local order = k * 0.5
		local firing = order % 3 == 0
		local half = order % 1 ~= 0
		seed = (seed * 1103515245 + 12345) % 2147483648
		orders[#orders + 1] = {
			frequency = REV * order,
			amplitude = (firing and 1 or half and 0.3 or 0.45) / order ^ 0.6,
			phase = seed / 2147483648 * 2 * math.pi,
		}
	end

	for i = 0, frames - 1 do
		local t = i / SAMPLE_RATE
		local sum = 0

		for _, o in ipairs(orders) do
			sum = sum + o.amplitude * math.sin(2 * math.pi * o.frequency * t + o.phase)
		end

		local pulse = 0.5 + 0.5 * math.cos(2 * math.pi * REV * 3 * t)
		engine[i] = sum + rasp[i] * pulse * pulse * 2.5
	end

	normalize(engine, frames)
	local sound = looping_source(engine, frames, 10 ^ (14 / 20))
	local car = marker("f1 car", ORIGIN + Vec3(0, 0.5, 0), MARKERS.car, Vec3(5.6, 0.95, 2))
	box(
		"f1 ground",
		ORIGIN + Vec3(0, -0.5, RADIUS),
		Vec3(STRAIGHT + 2 * RADIUS + 300, 1, 2 * RADIUS + 300),
		MATERIALS.grass
	)

	for side = 0, 1 do
		box(
			"f1 straight " .. side,
			ORIGIN + Vec3(0, 0.01, side * 2 * RADIUS),
			Vec3(STRAIGHT, 0.04, 14),
			MATERIALS.asphalt
		)

		for k = 0, 23 do
			local angle = (k + 0.5) / 24 * math.pi
			local sign = side == 0 and 1 or -1
			local center = ORIGIN + Vec3(sign * STRAIGHT / 2, 0.01, RADIUS)
			local direction = Vec3(sign * math.sin(angle), 0, -math.cos(angle))
			box(
				"f1 corner " .. side .. " " .. k,
				center + direction * RADIUS,
				Vec3(14, 0.04, 2 * math.pi * RADIUS / 48 + 1),
				MATERIALS.asphalt,
				QuatDeg3(0, -math.deg(math.atan2(direction.z, direction.x)), 0)
			)
		end
	end

	local function track_position(s)
		s = s % LENGTH

		if s < STRAIGHT then return ORIGIN + Vec3(-STRAIGHT / 2 + s, 0.5, 0), false end

		s = s - STRAIGHT

		if s < math.pi * RADIUS then
			local angle = s / RADIUS
			return ORIGIN + Vec3(STRAIGHT / 2 + math.sin(angle) * RADIUS, 0.5, RADIUS - math.cos(angle) * RADIUS),
			true
		end

		s = s - math.pi * RADIUS

		if s < STRAIGHT then
			return ORIGIN + Vec3(STRAIGHT / 2 - s, 0.5, 2 * RADIUS), false
		end

		local angle = (s - STRAIGHT) / RADIUS
		return ORIGIN + Vec3(-STRAIGHT / 2 - math.sin(angle) * RADIUS, 0.5, RADIUS + math.cos(angle) * RADIUS),
		true
	end

	local function distance_to_corner(s)
		s = s % LENGTH
		local half = STRAIGHT + math.pi * RADIUS
		local into = s % half
		return into < STRAIGHT and STRAIGHT - into or 0
	end

	local state = {s = 0, speed = CORNER_SPEED, gear = 6, rpm = 10000, throttle = true}
	showcase.scenes[#showcase.scenes + 1] = {
		name = "f1",
		title = "formula 1 pass by",
		sounds = {sound},
		center = ORIGIN + Vec3(0, 0, RADIUS),
		radius = STRAIGHT / 2 + RADIUS + 150,
		listener = ORIGIN + Vec3(0, 0, -14),
		describe = function(lines)
			local listener = audio.GetListenerPosition()
			local position = track_position(state.s)
			local to_listener = (listener - position):GetNormalized()
			local heading = (track_position(state.s + 1) - position):GetNormalized()
			local c = audio.speed_of_sound
			local ratio = c / (c - heading:GetDot(to_listener) * state.speed)
			lines[#lines + 1] = string.format(
				"%3.0f km/h  gear %d  %5.0f rpm  %s",
				state.speed * 3.6,
				state.gear,
				state.rpm,
				state.throttle and "throttle" or "braking"
			)
			lines[#lines + 1] = string.format(
				"engine %.0f Hz firing, doppler %+.1f semitones, %.0f m away",
				state.rpm / 60 * 3,
				12 * math.log(ratio) / math.log(2),
				(listener - position):GetLength()
			)
			lines[#lines + 1] = "a lap is 1.9 km; shifts drop the engine 3 semitones, the pass drops it ~8"
		end,
		update = function(dt)
			local corner = select(2, track_position(state.s))
			local limit = corner and
				CORNER_SPEED or
				math.sqrt(CORNER_SPEED ^ 2 + 2 * BRAKE * distance_to_corner(state.s))

			if state.speed > limit + 0.5 then
				state.speed = math.max(state.speed - BRAKE * dt, limit)
				state.throttle = false
			else
				state.speed = math.min(state.speed + LAUNCH * (1 - state.speed / TOP_SPEED) * dt, limit)
				state.throttle = true
			end

			state.s = state.s + state.speed * dt
			local gear_speed = FIRST_GEAR_SPEED * GEAR_STEP ^ (state.gear - 1)
			state.rpm = REDLINE * state.speed / gear_speed

			if state.rpm > UPSHIFT and state.gear < GEARS then
				state.gear = state.gear + 1
			elseif state.rpm < DOWNSHIFT and state.gear > 1 then
				state.gear = state.gear - 1
			end

			state.rpm = math.max(REDLINE * state.speed / (FIRST_GEAR_SPEED * GEAR_STEP ^ (state.gear - 1)), 4000)
			local position = track_position(state.s)
			local heading = track_position(state.s + 1) - position
			car.transform:SetPosition(position)
			car.transform:SetRotation(QuatDeg3(0, -math.deg(math.atan2(heading.z, heading.x)), 0))
			sound:SetPosition(position)
			sound:SetPitch(state.rpm / (REV * 60))
			sound:SetGain(10 ^ ((state.throttle and 14 or 6) / 20))
			sound:SetBandGains(state.throttle and Vec3(1, 1, 1) or Vec3(1, 0.8, 0.5))

			if not sound:IsPlaying() then sound:Play() end
		end,
		label = function()
			return track_position(state.s) + Vec3(0, 2, 0),
			string.format("F1 %.0f km/h", state.speed * 3.6)
		end,
	}
end

do
	-- a narrow canyon: one cliff close behind, the other far in front
	local ORIGIN = Vec3(3000, 0, 0)
	local NEAR = 15
	local FAR = 170
	local clap, clap_frames = signals.Clap(44100)
	local sound = one_shot_source(clap, clap_frames, 44100, 10 ^ (6 / 20))
	local source = ORIGIN + Vec3(0, EYE, -3)
	marker("canyon source", source, MARKERS.source)
	box(
		"canyon floor",
		ORIGIN + Vec3(0, -0.5, (FAR - NEAR) / 2),
		Vec3(800, 1, FAR + NEAR + 20),
		MATERIALS.rock
	)
	box(
		"canyon near cliff",
		ORIGIN + Vec3(0, 40, -NEAR - 3),
		Vec3(800, 80, 6),
		MATERIALS.rock
	)
	box(
		"canyon far cliff",
		ORIGIN + Vec3(0, 40, FAR + 3),
		Vec3(800, 80, 6),
		MATERIALS.rock
	)
	local next_shot = 0
	local c = audio.speed_of_sound
	showcase.scenes[#showcase.scenes + 1] = {
		name = "canyon",
		title = "canyon echo",
		sounds = {sound},
		center = ORIGIN + Vec3(0, 0, FAR / 2),
		radius = 400,
		listener = ORIGIN,
		describe = function(lines)
			local listener = audio.GetListenerPosition()
			local near = 2 * (listener.z - ORIGIN.z + NEAR) / c
			local far = 2 * (ORIGIN.z + FAR - listener.z) / c
			lines[#lines + 1] = string.format(
				"a clap every 5 s: near cliff echo %.0f ms, far cliff %.2f s, both %.2f s, then flutter",
				near * 1000,
				far,
				near + far
			)
			lines[#lines + 1] = "audio_showcase_clap plays one now"
		end,
		update = function(dt, time)
			if time >= next_shot then
				next_shot = time + 5
				sound:SetPosition(source)
				sound:Play()
			end
		end,
		trigger = function()
			sound:SetPosition(source)
			sound:Play()
		end,
	}
end

do
	-- a jet passing low over open ground: you see it before you hear it, and far away it is dull
	local ORIGIN = Vec3(-3000, 0, 0)
	local ALTITUDE = 120
	local SPEED = 170
	local RANGE = 4000
	local PAUSE = 6
	-- generated while it plays (audio.CreateStream): no loop to hear, the noise never repeats
	local ROAR_CUTOFF = 1800
	local roar_k = 1 - math.exp(-2 * math.pi * ROAR_CUTOFF / SAMPLE_RATE)
	local swell_k = 1 / (0.3 * SAMPLE_RATE)
	local jet_state = {
		seed = 23,
		low_a = 0,
		low_b = 0,
		swell = 1,
		swell_target = 1,
		until_swell = 0,
		phase_a = 0,
		phase_b = 0,
	}

	local function fill_jet(data, from, count)
		local st = jet_state
		local seed, low_a, low_b = st.seed, st.low_a, st.low_b
		local swell, swell_target, until_swell = st.swell, st.swell_target, st.until_swell
		local phase_a, phase_b = st.phase_a, st.phase_b

		for i = from, from + count - 1 do
			seed = (seed * 16807) % 2147483647
			local white = seed / 1073741823.5 - 1
			low_a = low_a + (white - low_a) * roar_k
			low_b = low_b + (low_a - low_b) * roar_k
			until_swell = until_swell - 1

			-- turbulence: the roar drifts in level a few times a second
			if until_swell <= 0 then
				seed = (seed * 16807) % 2147483647
				swell_target = 0.75 + 0.5 * seed / 2147483647
				until_swell = SAMPLE_RATE * 0.25
			end

			swell = swell + (swell_target - swell) * swell_k
			phase_a = (phase_a + 2 * math.pi * 3550 / SAMPLE_RATE) % (2 * math.pi)
			phase_b = (phase_b + 2 * math.pi * 7100 / SAMPLE_RATE) % (2 * math.pi)
			data[i] = math.clamp(
				low_b * 3.5 * swell + white * 0.06 + 0.04 * math.sin(phase_a) + 0.02 * math.sin(phase_b),
				-1,
				1
			)
		end

		st.seed, st.low_a, st.low_b = seed, low_a, low_b
		st.swell, st.swell_target, st.until_swell = swell, swell_target, until_swell
		st.phase_a, st.phase_b = phase_a, phase_b
	end

	local sound = audio.CreateStream(fill_jet, 2, SAMPLE_RATE, 1)
	sound:SetNormalized(true)
	sound:SetReferenceDistance(2)
	sound:SetGain(10 ^ (30 / 20))
	showcase.sounds[#showcase.sounds + 1] = sound
	local jet = marker("jet", ORIGIN + Vec3(0, ALTITUDE, -RANGE), MARKERS.car, Vec3(10, 3, 16))
	box("jet ground", ORIGIN + Vec3(0, -0.5, 0), Vec3(1200, 1, 1200), MATERIALS.grass)
	local period = 2 * RANGE / SPEED + PAUSE

	local function jet_position(time)
		local t = time % period
		return ORIGIN + Vec3(40, ALTITUDE, -RANGE + SPEED * math.min(t, 2 * RANGE / SPEED)),
		t < 2 * RANGE / SPEED
	end

	local now = 0
	showcase.scenes[#showcase.scenes + 1] = {
		name = "flyover",
		title = "jet flyover",
		sounds = {sound},
		center = ORIGIN,
		radius = 600,
		listener = ORIGIN,
		describe = function(lines)
			local listener = audio.GetListenerPosition()
			local position = jet_position(now)
			local distance = (position - listener):GetLength()
			lines[#lines + 1] = string.format(
				"%.0f m/s at %d m: %.0f m away, the sound you hear left it %.1f s ago",
				SPEED,
				ALTITUDE,
				distance,
				distance / audio.speed_of_sound
			)
			lines[#lines + 1] = string.format(
				"air takes %.0f dB of the high band, %.0f dB of the mid band over that distance",
				-20 * math.log10(spatial.AirAbsorption(3, distance)),
				-20 * math.log10(spatial.AirAbsorption(2, distance))
			)
		end,
		update = function(dt, time)
			now = time
			local position, flying = jet_position(time)
			jet.transform:SetPosition(position)
			sound:SetPosition(position)

			if flying and not sound:IsPlaying() then
				sound:Play()
			elseif not flying and sound:IsPlaying() then
				sound:Stop()
			end
		end,
		label = function()
			return jet_position(now), "jet"
		end,
	}
end

do
	-- a free standing wall in a field: walk around it and hear the sound bend around the edges
	local ORIGIN = Vec3(0, 0, 3000)
	local frames = SAMPLE_RATE * 2
	local radio = ffi.new("float[?]", frames)
	local notes = {220, 277.18, 329.63, 440}

	for i = 0, frames - 1 do
		local t = i / SAMPLE_RATE
		local note = notes[math.floor(t * 2) % #notes + 1]
		local sum = 0

		for k = 1, 12 do
			sum = sum + math.sin(2 * math.pi * note * k * t) / k
		end

		radio[i] = sum * (1 - math.exp(-(t * 2 % 1) * 40)) * math.exp(-(t * 2 % 1) * 2)
	end

	normalize(radio, frames)
	local sound = looping_source(radio, frames, 1)
	local source = ORIGIN + Vec3(0, EYE, -4)
	marker("wall source", source, MARKERS.source)
	box("wall ground", ORIGIN + Vec3(0, -0.5, 0), Vec3(200, 1, 200), MATERIALS.grass)
	box("wall", ORIGIN + Vec3(0, 1.5, -2), Vec3(8, 3, 0.3), MATERIALS.concrete)
	showcase.scenes[#showcase.scenes + 1] = {
		name = "wall",
		title = "diffraction around a wall",
		sounds = {sound},
		center = ORIGIN,
		radius = 100,
		listener = ORIGIN + Vec3(0, 0, 6),
		describe = function(lines)
			local env = sound.audio_environment

			if env then
				lines[#lines + 1] = string.format(
					"shortest way around %.2f m, around %.0f/%.0f/%.0f dB, through %.0f/%.0f/%.0f dB",
					env.detour >= acoustics.DETOUR_NONE and math.huge or env.detour,
					10 * math.log10(math.max(env.diffraction[1], 1e-12)),
					10 * math.log10(math.max(env.diffraction[2], 1e-12)),
					10 * math.log10(math.max(env.diffraction[3], 1e-12)),
					10 * math.log10(math.max(env.transmission[1], 1e-12)),
					10 * math.log10(math.max(env.transmission[2], 1e-12)),
					10 * math.log10(math.max(env.transmission[3], 1e-12))
				)
			end

			lines[#lines + 1] = "8 m wide, 3 m tall concrete; walk behind it and out to the side"
		end,
		update = function()
			sound:SetPosition(source)

			if not sound:IsPlaying() then sound:Play() end
		end,
	}
end

do
	-- a wooden shelter with a metal roof in the rain: the rain moves to the door and drums through the roof
	local ORIGIN = Vec3(0, 0, -3000)
	local W, H, D = 4, 2.6, 5
	box("shelter ground", ORIGIN + Vec3(0, -0.5, 0), Vec3(200, 1, 200), MATERIALS.grass)
	box(
		"shelter roof",
		ORIGIN + Vec3(0, H + 0.05, 0),
		Vec3(W + 0.6, 0.1, D + 0.6),
		MATERIALS.metal
	)
	box("shelter back", ORIGIN + Vec3(0, H / 2, -D / 2), Vec3(W, H, 0.1), MATERIALS.wood)
	box("shelter left", ORIGIN + Vec3(-W / 2, H / 2, 0), Vec3(0.1, H, D), MATERIALS.wood)
	box("shelter right", ORIGIN + Vec3(W / 2, H / 2, 0), Vec3(0.1, H, D), MATERIALS.wood)
	box(
		"shelter front left",
		ORIGIN + Vec3(-W / 2 + 0.75, H / 2, D / 2),
		Vec3(1.5, H, 0.1),
		MATERIALS.wood
	)
	box(
		"shelter front right",
		ORIGIN + Vec3(W / 2 - 0.75, H / 2, D / 2),
		Vec3(1.5, H, 0.1),
		MATERIALS.wood
	)
	box(
		"shelter lintel",
		ORIGIN + Vec3(0, H - 0.3, D / 2),
		Vec3(1, 0.6, 0.1),
		MATERIALS.wood
	)
	local climate = import("goluwa/render3d/climate.lua")
	local ambience = import("lua/ambience.lua")
	-- rain: thousands of drop impacts a second, each a short click or a ringing bubble, over a hiss of the distant ones
	local RAIN_SECONDS = 4
	local rain_frames = SAMPLE_RATE * RAIN_SECONDS
	local rain = looping_noise(rain_frames, 41)
	lowpass(rain, rain_frames, 2500)
	local seed = 7

	local function random()
		seed = (seed * 16807) % 2147483647
		return seed / 2147483647
	end

	for i = 0, rain_frames - 1 do
		rain[i] = rain[i] * 0.15
	end

	for _ = 1, 3000 * RAIN_SECONDS do
		local at = math.floor(random() * rain_frames)
		local amplitude = math.exp((random() - 0.7) * 2.5)

		if random() < 0.3 then
			local frequency = 1500 * (4 ^ random())
			local decay = (0.003 + 0.008 * random()) * SAMPLE_RATE
			local phase = 0

			for k = 0, math.floor(decay * 4) do
				phase = phase + 2 * math.pi * frequency * (1 + 0.3 * k / decay) / SAMPLE_RATE
				local i = (at + k) % rain_frames
				rain[i] = rain[i] + amplitude * 0.5 * math.sin(phase) * math.exp(-k / decay)
			end
		else
			local length = math.floor((0.0008 + 0.002 * random()) * SAMPLE_RATE)
			local y = 0

			for k = 0, length * 3 do
				local i = (at + k) % rain_frames
				y = y + ((random() * 2 - 1) - y) * 0.6
				rain[i] = rain[i] + amplitude * y * math.exp(-k / length)
			end
		end
	end

	normalize(rain, rain_frames)

	local function create_rain()
		local sound = audio.CreateSource{data = rain, samples = rain_frames, channels = 1, sample_rate = SAMPLE_RATE}
		sound:SetNormalized(true)
		sound:SetReferenceDistance(2)
		sound:SetLooping(true)
		sound:SetTraced(false)
		showcase.sounds[#showcase.sounds + 1] = sound
		return sound
	end

	showcase.scenes[#showcase.scenes + 1] = {
		name = "shelter",
		title = "rain shelter",
		sounds = {},
		center = ORIGIN,
		radius = 100,
		listener = ORIGIN,
		describe = function(lines)
			local gathered = audio.acoustics and audio.trace_ambience and audio.acoustics:GetAmbience()

			if gathered then
				lines[#lines + 1] = string.format(
					"rain %.0f dB against open ground, strongest from %s",
					10 * math.log10(math.max(gathered.rain[2] / (0.5 * acoustics.DEFAULT_MATERIAL.rain[2]), 1e-9)),
					gathered.bins[1] and tostring(gathered.bins[1].direction) or "nowhere"
				)
			end

			lines[#lines + 1] = "synthetic rain from the game addon's ambience; walk in and out of the door"
		end,
		enter = function()
			ambience.SetSource("rain", create_rain)
			climate.SetPreset("rain", 2)
		end,
		leave = function()
			ambience.SetSource("rain", nil)
			climate.SetPreset({}, 2)
		end,
	}
end

do
	-- a city grid: an ambulance circles the four middle blocks while you stand at the crossing between them
	local ORIGIN = Vec3(3000, 0, 3000)
	local BLOCK = 40
	local STREET = 14
	local PITCH = BLOCK + STREET
	local SPEED = 13
	local CORNER_SPEED = 5
	local HIGH, LOW = 620, 465
	-- the two tones of a European siren, 0.6 s each with whole cycles so the loop has no step
	local TONE = 0.6
	local frames = math.floor(SAMPLE_RATE * TONE * 2)
	local siren = ffi.new("float[?]", frames)

	for i = 0, frames - 1 do
		local t = i / SAMPLE_RATE
		local frequency = t < TONE and HIGH or LOW
		local local_t = t < TONE and t or t - TONE
		local sum = 0

		for k = 1, 15, 2 do
			sum = sum + math.sin(2 * math.pi * frequency * k * local_t) / k
		end

		siren[i] = sum
	end

	normalize(siren, frames)
	local sound = looping_source(siren, frames, 10 ^ (20 / 20))
	local ambulance = marker("ambulance", ORIGIN, MARKERS.ambulance, Vec3(6, 2.6, 2.4))
	box(
		"city ground",
		ORIGIN + Vec3(0, -0.5, 0),
		Vec3(4 * PITCH + 200, 1, 4 * PITCH + 200),
		MATERIALS.asphalt
	)
	local seed = 3

	for i = 0, 3 do
		for j = 0, 3 do
			seed = (seed * 16807) % 2147483647
			local height = 10 + 25 * seed / 2147483647
			box(
				"city block " .. i .. " " .. j,
				ORIGIN + Vec3((i - 1.5) * PITCH, height / 2, (j - 1.5) * PITCH),
				Vec3(BLOCK, height, BLOCK),
				MATERIALS.concrete
			)
		end
	end

	-- the street ring between the middle four blocks and the outer ones
	local corners = {
		ORIGIN + Vec3(-PITCH, 1.3, -PITCH),
		ORIGIN + Vec3(PITCH, 1.3, -PITCH),
		ORIGIN + Vec3(PITCH, 1.3, PITCH),
		ORIGIN + Vec3(-PITCH, 1.3, PITCH),
	}
	local side = 2 * PITCH
	local lap = 4 * side
	local state = {s = side / 2, speed = SPEED}

	local function route(s)
		s = s % lap
		local leg = math.floor(s / side)
		local from, to = corners[leg + 1], corners[(leg + 1) % 4 + 1]
		local along = s - leg * side
		return from + (to - from) * (along / side),
		(to - from):GetNormalized(),
		math.min(along, side - along)
	end

	showcase.scenes[#showcase.scenes + 1] = {
		name = "city",
		title = "ambulance in a city",
		sounds = {sound},
		center = ORIGIN,
		radius = 2 * PITCH + 100,
		listener = ORIGIN,
		describe = function(lines)
			local listener = audio.GetListenerPosition()
			local position, heading = route(state.s)
			local to_listener = (listener - position):GetNormalized()
			local c = audio.speed_of_sound
			local ratio = c / (c - heading:GetDot(to_listener) * state.speed)
			local env = sound.audio_environment
			lines[#lines + 1] = string.format(
				"%.0f km/h, %.0f m away, doppler %+.2f semitones",
				state.speed * 3.6,
				(listener - position):GetLength(),
				12 * math.log(ratio) / math.log(2)
			)

			if env then
				local taps = 0

				for _ in pairs(env.taps) do
					taps = taps + 1
				end

				lines[#lines + 1] = string.format(
					"direct %.0f/%.0f/%.0f dB, reverb send %.2f, %d reflections",
					20 * math.log10(math.max(env.occlusion[1], 1e-6)),
					20 * math.log10(math.max(env.occlusion[2], 1e-6)),
					20 * math.log10(math.max(env.occlusion[3], 1e-6)),
					env.send[1] + env.send[2],
					taps
				)
			end

			lines[#lines + 1] = "it circles the middle four blocks; you hear it down the streets, around corners and off the facades"
		end,
		update = function(dt)
			local _, _, to_corner = route(state.s)
			local target = math.min(SPEED, CORNER_SPEED + to_corner * 0.4)
			state.speed = state.speed + (target - state.speed) * math.min(dt * 2, 1)
			state.s = state.s + state.speed * dt
			local position, heading = route(state.s)
			ambulance.transform:SetPosition(position)
			ambulance.transform:SetRotation(QuatDeg3(0, -math.deg(math.atan2(heading.z, heading.x)), 0))
			sound:SetPosition(position + Vec3(0, 1.4, 0))

			if not sound:IsPlaying() then sound:Play() end
		end,
		label = function()
			return route(state.s) + Vec3(0, 3, 0), "ambulance"
		end,
	}
end

function showcase.Goto(name)
	for _, scene in ipairs(showcase.scenes) do
		if scene.name == name then
			local rig = _G.PLAYER_RIG

			if rig then
				rig.character_movement:TeleportTo(scene.listener + Vec3(0, 0.05, 0))
			else
				audio.SetListenerPosition(scene.listener + Vec3(0, EYE, 0))
			end

			logn("audio_showcase: ", scene.title, " at ", scene.listener)
			return scene
		end
	end
end

commands.Add("audio_showcase=string|nil", function(name)
	if not name or not showcase.Goto(name) then
		for _, scene in ipairs(showcase.scenes) do
			logn(scene.name, ": ", scene.title)
		end
	end
end)

commands.Add("audio_showcase_clap", function()
	for _, scene in ipairs(showcase.scenes) do
		if scene.trigger then scene.trigger() end
	end
end)

local function current_scene()
	local listener = audio.GetListenerPosition()

	for _, scene in ipairs(showcase.scenes) do
		local offset = listener - scene.center

		if math.abs(offset.x) < scene.radius and math.abs(offset.z) < scene.radius then
			return scene
		end
	end
end

local start = system.GetElapsedTime()
local last = start
local active

event.AddListener("Update", "audio_showcase", function()
	local now = system.GetElapsedTime()
	local dt = math.min(now - last, 0.1)
	last = now
	local scene = current_scene()

	if scene ~= active then
		if active then
			for _, sound in ipairs(active.sounds) do
				sound:Stop()
			end

			if active.leave then active.leave() end
		end

		if scene and scene.enter then scene.enter() end

		active = scene
	end

	if scene and scene.update then scene.update(dt, now - start) end

	if scene and scene.label then
		local position, text = scene.label()
		debug_draw.DrawText{
			id = "audio_showcase label",
			position = position,
			lines = {text},
			time = 0.2,
			padding = 4,
			background_alpha = 0.5,
			text_color = Color(1, 0.9, 0.8, 1),
		}
	end
end)

event.AddListener("Draw2D", "audio_showcase", function()
	local scene = current_scene()
	local lines = {}

	if scene then
		lines[#lines + 1] = scene.title
		scene.describe(lines)
	else
		lines[#lines + 1] = "audio showcase"
	end

	local names = {}

	for _, s in ipairs(showcase.scenes) do
		names[#names + 1] = s.name
	end

	lines[#lines + 1] = "audio_showcase <" .. table.concat(names, "|") .. "> teleports"
	debug_draw.DrawTextBlock(
		lines,
		16,
		16,
		{
			padding = 8,
			line_gap = 3,
			background_alpha = 0.7,
			title_color = Color(0.7, 0.9, 1, 1),
			text_color = Color(0.9, 0.9, 0.94, 1),
		}
	)
end)

logn(
	"audio_showcase: ",
	#showcase.scenes,
	" scenes, audio_showcase <name> to go there"
)
