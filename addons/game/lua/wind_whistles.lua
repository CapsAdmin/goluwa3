local audio = import("goluwa/audio.lua")
local event = import("goluwa/event.lua")
local pvars = import("goluwa/cli/pvars.lua")
local physics = import("goluwa/physics.lua")
local shelter = import("goluwa/shelter.lua")
local RigidBody = import("goluwa/physics/rigid_body.lua")
local weather = import("goluwa/render3d/weather.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local wind_whistles = {}
local SAMPLE_RATE = 24000
local BUFFER_SECONDS = 0.3
local MAX_DIAMETER = 0.3
local MIN_LENGTH = 1.2
local MIN_SLENDERNESS = 5
local CLASSIFY_PER_FRAME = 64
local RANGE_SQUARED = 50 ^ 2
local SELECT_INTERVAL = 0.25
local STROUHAL = 0.2
local MIN_SPEED = 3
local REFERENCE_SPEED = 15
local BASE_GAIN = 10 ^ (-30 / 20)
local MIN_FREQUENCY = 40
local MAX_FREQUENCY = 3000
local RADIUS = 0.9985
local PARTIALS = {{1, 1}, {2, 0.8}, {3, 0.5}}
local OUTPUT = 0.2 / math.sqrt(1 + 0.8 * 0.8 + 0.5 * 0.5)
local WANDER = 0.06
local WANDER_TIME = 3
local GATE_TIME = 2.5
local GATE_DEPTH = 0.5
local METAL_LEVEL = 1
local OTHER_LEVEL = 0.6
local SHELTER_DISTANCE = 12
local SHELTERED = 0.15
local GAIN_TIME = 0.15
local FREQUENCY_TIME = 0.1
local STOP_GAIN = 1e-4
pvars.StartGroup("Engine", "Audio", {prefix = "audio_"})
local voice_count = pvars.Setup2{
	key = "audio_wind_whistles",
	default = 4,
	min = 0,
	max = 8,
	friendly = "wind whistles",
	help = "how many thin objects (poles, pipes, rails) whistle in the wind at once, nearest and loudest first, 0 turns them off",
}
pvars.EndGroup()
local radius_squared = RADIUS * RADIUS
local candidates = {}
local classified = table.weak("k")
local cursor = 1
local voices = {}
wind_whistles.voices = voices
wind_whistles.candidates = candidates
local METAL = {
	metal = true,
	metal_vent = true,
	metal_box = true,
	metal_barrel = true,
	canister = true,
	metal_grate = true,
	chainlink = true,
	chain = true,
	ladder = true,
	vehicle = true,
	weapon = true,
}
local chosen = {}
local chosen_level = {}

local function classify(body)
	local half = body:GetHalfExtents()
	local bounds = body.LocalBounds
	local sizes = {2 * half.x, 2 * half.y, 2 * half.z}
	local long = sizes[1] >= sizes[2] and
		sizes[1] >= sizes[3] and
		1 or
		sizes[2] >= sizes[3] and
		2 or
		3
	local length = sizes[long]
	local a, b = sizes[long % 3 + 1], sizes[(long + 1) % 3 + 1]

	if
		math.max(a, b) > MAX_DIAMETER or
		length < MIN_LENGTH or
		length / math.max(a, b, 0.01) < MIN_SLENDERNESS
	then
		return
	end

	local local_axis = Vec3(long == 1 and 1 or 0, long == 2 and 1 or 0, long == 3 and 1 or 0)
	local rotation = body.Rotation
	local material = physics.GetHitMaterial({entity = body.Owner})
	local surface = material and material:GetSurfaceType() or body.SurfaceType or "default"
	candidates[#candidates + 1] = {
		body = body,
		diameter = math.sqrt(a * b),
		length = length,
		position = body.Position + rotation:VecMul((bounds.min + bounds.max) * 0.5),
		axis = rotation:VecMul(local_axis):GetNormalized(),
		level = METAL[surface] and METAL_LEVEL or OTHER_LEVEL,
		seed = #candidates * 7919 + 13,
	}
end

local function uniform(voice)
	voice.seed = (voice.seed * 16807) % 2147483647
	return voice.seed / 1073741823.5 - 1
end

local function fill(voice, data, from, count)
	local partials = voice.partials

	for p = 1, #PARTIALS do
		local partial = partials[p]
		local cosine = math.cos(2 * math.pi * PARTIALS[p][1] * voice.frequency / SAMPLE_RATE)
		partial.coefficient = 2 * RADIUS * cosine
		partial.norm = PARTIALS[p][2] / math.sqrt(
				(
						1 + radius_squared
					) / (
						3 * (
							1 - radius_squared
						) * (
							(
								1 + radius_squared
							) ^ 2 - 4 * radius_squared * cosine * cosine
						)
					)
			)
	end

	for i = from, from + count - 1 do
		local value = 0

		for p = 1, #PARTIALS do
			local partial = partials[p]
			local y = partial.coefficient * partial.y1 - radius_squared * partial.y2 + uniform(voice)
			partial.y2 = partial.y1
			partial.y1 = y
			value = value + y * partial.norm
		end

		data[i] = value * OUTPUT
	end
end

local function create_voice(index)
	local voice = {
		seed = 4000 + index * 6151,
		frequency = 600,
		partials = {},
		gain = 0,
		sheltered = 0,
		wander = 0,
		gate = 0,
		playing = false,
	}

	for p = 1, #PARTIALS do
		voice.partials[p] = {y1 = 0, y2 = 0, coefficient = 0, norm = 1}
	end

	voice.sound = audio.CreateStream(
		function(data, from, count)
			fill(voice, data, from, count)
		end,
		BUFFER_SECONDS,
		SAMPLE_RATE,
		1
	)
	voice.sound:SetNormalized(true)
	voice.sound:SetReferenceDistance(2)
	return voice
end

local select_time = 0

local function select_candidates(listener, wind, count)
	local used = 0

	for i = 1, #candidates do
		local entry = candidates[i]
		local offset = entry.position - listener
		local distance_squared = offset:GetLengthSquared()

		if distance_squared < RANGE_SQUARED then
			local along = wind:GetDot(entry.axis)
			local perpendicular = (wind - entry.axis * along):GetLength()

			if perpendicular >= MIN_SPEED then
				entry.perpendicular = perpendicular
				local level = (
						perpendicular / REFERENCE_SPEED
					) ^ 3 * entry.level / math.max(math.sqrt(distance_squared), 2)
				local at = used + 1

				while at > 1 and chosen_level[at - 1] < level do
					at = at - 1
				end

				if at <= count then
					for j = math.min(used + 1, count), at + 1, -1 do
						chosen[j] = chosen[j - 1]
						chosen_level[j] = chosen_level[j - 1]
					end

					chosen[at] = entry
					chosen_level[at] = level
					used = math.min(used + 1, count)
				end
			end
		end
	end

	for i = used + 1, count do
		chosen[i] = nil
	end

	return used
end

event.AddListener("Update", "wind_whistles", function(dt)
	if not audio.initialized then return end

	local count = math.floor(voice_count:Get())
	local bodies = RigidBody.Instances

	for _ = 1, CLASSIFY_PER_FRAME do
		local body = bodies[cursor]

		if not body then
			cursor = 1

			break
		end

		cursor = cursor + 1

		if not classified[body] then
			classified[body] = true

			if
				body.MotionType == "static" and
				not body.WorldGeometry and
				not body.Owner.terrain_data
			then
				classify(body)
			end
		end
	end

	local wind = weather.GetWind()
	local wind_speed = wind:GetLength()
	local listener = audio.GetListenerPosition()
	select_time = select_time - dt

	if select_time <= 0 then
		select_time = SELECT_INTERVAL
		local used = count > 0 and
			wind_speed >= MIN_SPEED and
			select_candidates(listener, wind, count) or
			0

		for i = 1, math.max(count, #voices) do
			local entry = i <= count and chosen[i] or nil
			local voice = voices[i]

			if not voice and entry then
				voice = create_voice(i)
				voices[i] = voice
			end

			if voice then
				voice.desired = entry

				if entry and entry == voice.entry then
					voice.sheltered = shelter.GetAgainst(entry.position, wind, SHELTER_DISTANCE, entry.body.Owner)
				end
			end
		end
	end

	local gain_k = 1 - math.exp(-dt / GAIN_TIME)
	local frequency_k = 1 - math.exp(-dt / FREQUENCY_TIME)

	for i = 1, #voices do
		local voice = voices[i]
		local sound = voice.sound
		local target = 0

		if voice.entry ~= voice.desired and voice.gain <= STOP_GAIN then
			voice.entry = voice.desired
			voice.sheltered = 0
		end

		local entry = voice.entry

		if entry and entry == voice.desired then
			local perpendicular = (wind - entry.axis * wind:GetDot(entry.axis)):GetLength()
			voice.wander = voice.wander - voice.wander * dt / WANDER_TIME + uniform(voice) * 1.7320508 * math.sqrt(2 * dt / WANDER_TIME)
			voice.gate = voice.gate - voice.gate * dt / GATE_TIME + uniform(voice) * 1.7320508 * math.sqrt(2 * dt / GATE_TIME)
			local frequency = math.clamp(
				STROUHAL * perpendicular / entry.diameter * (1 + WANDER * voice.wander),
				MIN_FREQUENCY,
				MAX_FREQUENCY
			)
			voice.frequency = voice.frequency + (frequency - voice.frequency) * frequency_k
			local reach = math.clamp(
				(listener - entry.position):GetDot(entry.axis),
				-entry.length * 0.5,
				entry.length * 0.5
			)
			sound:SetPosition(entry.position + entry.axis * reach)
			target = BASE_GAIN * (
					perpendicular / REFERENCE_SPEED
				) ^ 3 * entry.level * math.smoothstep(MIN_SPEED, MIN_SPEED + 3, perpendicular) * (
					1 - GATE_DEPTH + GATE_DEPTH * math.smoothstep(-0.5, 1, voice.gate)
				) * (
					1 - (
						1 - SHELTERED
					) * voice.sheltered
				)
		end

		voice.gain = voice.gain + (target - voice.gain) * gain_k

		if voice.gain > STOP_GAIN then
			sound:SetGain(voice.gain)

			if not voice.playing then
				sound:Play()
				voice.playing = true
			end
		elseif voice.playing then
			sound:Stop()
			voice.playing = false
		end
	end
end)

return wind_whistles
