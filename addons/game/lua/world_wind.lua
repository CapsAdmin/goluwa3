local audio = import("goluwa/audio.lua")
local event = import("goluwa/event.lua")
local pvars = import("goluwa/cli/pvars.lua")
local weather = import("goluwa/render3d/weather.lua")
local foliage_field = import("goluwa/foliage_field.lua")
local shelter = import("goluwa/shelter.lua")
local players = import("lua/players.lua")
local world_wind = {}
local SAMPLE_RATE = 24000
local BUFFER_SECONDS = 1
local OUTPUT = 0.08
local KNEE = 0.8
local RUMBLE_CUTOFF = 70
local BODY_BASE_CUTOFF = 200
local BODY_CUTOFF_PER_SPEED = 25
local WEIGHT_RUMBLE = 0.6
local WEIGHT_BODY = 0.8
local WEIGHT_WHISTLE = 0.5
local WEIGHT_RUSTLE = 0.7
local GUST_TIME = 4
local GUST_SIGMA = 0.35
local WHISTLE_START = 6
local WHISTLE_FULL = 18
local WHISTLE_STROUHAL = 0.2
local WHISTLE_DIAMETERS = {0.006, 0.0045}
local WHISTLE_MIN_FREQUENCY = 250
local WHISTLE_MAX_FREQUENCY = 2500
local WHISTLE_RADIUS = 0.9985
local WHISTLE_WANDER = 0.08
local WHISTLE_WANDER_TIME = 3
local WHISTLE_GATE_TIME = 2
local WHISTLE_DETUNE = 0.11
local RUSTLE_START = 2
local RUSTLE_FULL = 10
local RUSTLE_BANDS = {{600, 1800, 5}, {1500, 3600, 12}, {3000, 5600, 24}}
local RUSTLE_DEPTH = 0.7
local DENSITY_RADIUS = 30
local DENSITY_INTERVAL = 0.25
local DENSITY_GLIDE = 1
local SHELTER_RANGE = 20
local SHELTER_STRENGTH = 0.9
local SHELTER_GLIDE = 0.5
pvars.StartGroup("Engine", "Audio", {prefix = "audio_"})
local rumble_level = pvars.Setup2{
	key = "audio_wind_rumble",
	default = 1,
	min = 0,
	friendly = "wind rumble",
	help = "level of the low rumble in the wind of the world, 0 skips the layer",
}
local whistle_level = pvars.Setup2{
	key = "audio_wind_whistle",
	default = 1,
	min = 0,
	friendly = "wind whistle",
	help = "level of the tonal whistling in the wind of the world, 0 skips the layer",
}
local rustle_level = pvars.Setup2{
	key = "audio_wind_rustle",
	default = 1,
	min = 0,
	friendly = "wind rustle",
	help = "level of the rustling of vegetation in the wind of the world (scaled by the foliage around you), 0 skips the layer",
}
pvars.EndGroup()

local function one_pole(cutoff)
	return 1 - math.exp(-2 * math.pi * cutoff / SAMPLE_RATE)
end

local function one_pole_variance(k)
	return k / (2 - k) / 3
end

local function two_pole_variance(k)
	local a = 1 - k
	return k * (1 + a * a) / (2 - k) ^ 3 / 3
end

local rumble_k = one_pole(RUMBLE_CUTOFF)
local rumble_norm = 1 / math.sqrt(two_pole_variance(rumble_k))
local rustle_bands = {}

for i, band in ipairs(RUSTLE_BANDS) do
	local low_k, high_k, mod_k = one_pole(band[1]), one_pole(band[2]), one_pole(band[3])
	rustle_bands[i] = {
		low_k = low_k,
		high_k = high_k,
		mod_k = mod_k,
		norm = 1 / math.sqrt(
				one_pole_variance(low_k) + one_pole_variance(high_k) - 2 * low_k * high_k / (
						1 - (
							1 - low_k
						) * (
							1 - high_k
						)
					) / 3
			),
		mod_norm = 1 / math.sqrt(one_pole_variance(mod_k)),
	}
end

local rustle_power = math.sqrt(#RUSTLE_BANDS * (1 + RUSTLE_DEPTH * RUSTLE_DEPTH))
local wander_k = 1 - math.exp(-1 / (WHISTLE_WANDER_TIME * SAMPLE_RATE))
local whistle_radius_squared = WHISTLE_RADIUS * WHISTLE_RADIUS
local params = {
	speed = 0,
	gust = 1,
	rumble = WEIGHT_RUMBLE,
	body = WEIGHT_BODY,
	whistle = 0,
	rustle = 0,
	scale = OUTPUT / math.sqrt(WEIGHT_RUMBLE * WEIGHT_RUMBLE + WEIGHT_BODY * WEIGHT_BODY),
}
local voice_count = 0

local function uniform(voice)
	voice.seed = (voice.seed * 16807) % 2147483647
	return voice.seed / 1073741823.5 - 1
end

local function fill(voice, data, from, count)
	local body_k = one_pole(BODY_BASE_CUTOFF + BODY_CUTOFF_PER_SPEED * params.speed)
	local body_norm = 1 / math.sqrt(two_pole_variance(body_k))
	local chunk_seconds = count / SAMPLE_RATE
	local gust_a, gust_b = voice.gust, params.gust
	local rumble_a, rumble_b = voice.rumble, params.rumble * params.scale
	local body_a, body_b = voice.body, params.body * params.scale
	local rustle_a, rustle_b = voice.rustle, params.rustle * params.scale
	voice.gust, voice.rumble, voice.body, voice.rustle = gust_b, rumble_b, body_b, rustle_b
	local whistle = params.whistle * params.scale
	local radius = WHISTLE_RADIUS

	for r = 1, 2 do
		local resonator = voice.resonators[r]
		resonator.wander = resonator.wander + (
				-resonator.wander * chunk_seconds / WHISTLE_WANDER_TIME
			) + uniform(voice) * 1.7320508 * math.sqrt(2 * chunk_seconds / WHISTLE_WANDER_TIME)
		resonator.gate = resonator.gate + (
				-resonator.gate * chunk_seconds / WHISTLE_GATE_TIME
			) + uniform(voice) * 1.7320508 * math.sqrt(2 * chunk_seconds / WHISTLE_GATE_TIME)
		local frequency = math.clamp(
			WHISTLE_STROUHAL * params.speed / WHISTLE_DIAMETERS[r] * resonator.detune * (
					1 + WHISTLE_WANDER * resonator.wander
				),
			WHISTLE_MIN_FREQUENCY,
			WHISTLE_MAX_FREQUENCY
		)
		local cosine = math.cos(2 * math.pi * frequency / SAMPLE_RATE)
		resonator.coefficient = 2 * radius * cosine
		resonator.norm = 1 / math.sqrt(
				(
						1 + whistle_radius_squared
					) / (
						3 * (
							1 - whistle_radius_squared
						) * (
							(
								1 + whistle_radius_squared
							) ^ 2 - 4 * whistle_radius_squared * cosine * cosine
						)
					)
			)
		local gate_target = math.smoothstep(0.2, 1.2, resonator.gate)
		resonator.level_from, resonator.level_to = resonator.level, gate_target
		resonator.level = gate_target
	end

	local r1, r2 = voice.resonators[1], voice.resonators[2]

	for i = from, from + count - 1 do
		local t = (i - from) / count
		local gust = gust_a + (gust_b - gust_a) * t
		local white = uniform(voice)
		voice.rumble_a = voice.rumble_a + (white - voice.rumble_a) * rumble_k
		voice.rumble_b = voice.rumble_b + (voice.rumble_a - voice.rumble_b) * rumble_k
		white = uniform(voice)
		voice.body_a = voice.body_a + (white - voice.body_a) * body_k
		voice.body_b = voice.body_b + (voice.body_a - voice.body_b) * body_k
		local value = (
				rumble_a + (
					rumble_b - rumble_a
				) * t
			) * voice.rumble_b * rumble_norm * math.sqrt(gust) + (
				body_a + (
					body_b - body_a
				) * t
			) * voice.body_b * body_norm * gust

		if whistle > 0 then
			for r = 1, 2 do
				local resonator = voice.resonators[r]
				local y = resonator.coefficient * resonator.y1 - whistle_radius_squared * resonator.y2 + uniform(voice)
				resonator.y2 = resonator.y1
				resonator.y1 = y
				value = value + whistle * (
						resonator.level_from + (
							resonator.level_to - resonator.level_from
						) * t
					) * y * resonator.norm * gust
			end
		end

		local rustle = rustle_a + (rustle_b - rustle_a) * t

		if rustle > 0 then
			white = uniform(voice)
			local sum = 0

			for r = 1, #rustle_bands do
				local band, state = rustle_bands[r], voice.rustle_bands[r]
				state.low = state.low + (white - state.low) * band.low_k
				state.high = state.high + (white - state.high) * band.high_k
				state.mod = state.mod + (uniform(voice) - state.mod) * band.mod_k
				sum = sum + (
						state.high - state.low
					) * band.norm * math.max(0, 1 + RUSTLE_DEPTH * state.mod * band.mod_norm)
			end

			value = value + rustle * sum / rustle_power * gust
		end

		local magnitude = math.abs(value)

		if magnitude > KNEE then
			value = (
					value < 0 and
					-1 or
					1
				) * (
					KNEE + (
						1 - KNEE
					) * math.tanh((magnitude - KNEE) / (1 - KNEE))
				)
		end

		data[i] = value
	end
end

function world_wind.Create()
	voice_count = voice_count + 1
	local voice = {
		seed = 1000 + voice_count * 7919,
		gust = 1,
		rumble = 0,
		body = 0,
		rustle = 0,
		rumble_a = 0,
		rumble_b = 0,
		body_a = 0,
		body_b = 0,
		rustle_bands = {},
		resonators = {},
	}

	for r = 1, #RUSTLE_BANDS do
		voice.rustle_bands[r] = {low = 0, high = 0, mod = 0}
	end

	for r = 1, 2 do
		voice.resonators[r] = {
			y1 = 0,
			y2 = 0,
			wander = 0,
			gate = 0,
			level = 0,
			level_from = 0,
			level_to = 0,
			coefficient = 0,
			norm = 1,
			detune = 1 + WHISTLE_DETUNE * (voice_count % 3 - 1) * (r == 1 and 1 or -1),
		}
	end

	local sound = audio.CreateStream(
		function(data, from, count)
			fill(voice, data, from, count)
		end,
		BUFFER_SECONDS,
		SAMPLE_RATE,
		1
	)
	sound:SetNormalized(true)
	sound:SetReferenceDistance(2)
	return sound
end

do
	local gust_x = 0
	local density = 0
	local density_time = 0
	local sheltered = 0

	local function gaussian()
		return math.sqrt(-2 * math.log(1 - math.random())) * math.cos(2 * math.pi * math.random())
	end

	event.AddListener("Update", "world_wind", function(dt)
		local wind = weather.GetWind()
		gust_x = gust_x - gust_x * dt / GUST_TIME + GUST_SIGMA * math.sqrt(2 * dt / GUST_TIME) * gaussian()
		params.gust = math.exp(gust_x - GUST_SIGMA * GUST_SIGMA / 2)
		density_time = density_time - dt

		if density_time <= 0 and audio.initialized then
			density_time = DENSITY_INTERVAL
			local position = audio.GetListenerPosition()
			local target = foliage_field.GetDensity(position.x, position.z, DENSITY_RADIUS)
			density = density + (target - density) * (1 - math.exp(-DENSITY_INTERVAL / DENSITY_GLIDE))
			sheltered = sheltered + (
					shelter.GetAgainst(position, wind, SHELTER_RANGE, players.GetLocal()) - sheltered
				) * (
					1 - math.exp(-DENSITY_INTERVAL / SHELTER_GLIDE)
				)
		end

		local speed = audio.medium_velocity:GetLength() * (1 - SHELTER_STRENGTH * sheltered)
		params.speed = speed
		local rumble = WEIGHT_RUMBLE * rumble_level:Get()
		local whistle = WEIGHT_WHISTLE * whistle_level:Get() * math.smoothstep(WHISTLE_START, WHISTLE_FULL, speed)
		local rustle = WEIGHT_RUSTLE * rustle_level:Get() * density * math.smoothstep(RUSTLE_START, RUSTLE_FULL, speed)
		params.rumble = rumble
		params.body = WEIGHT_BODY
		params.whistle = whistle
		params.rustle = rustle
		params.scale = OUTPUT / math.sqrt(rumble * rumble + WEIGHT_BODY * WEIGHT_BODY + whistle * whistle + rustle * rustle)
	end)
end

return world_wind
