if not CLIENT or not AUDIO then return end

local audio = import("goluwa/audio.lua")
local event = import("goluwa/event.lua")
local pvars = import("goluwa/cli/pvars.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local shelter = import("goluwa/shelter.lua")
local players = import("lua/players.lua")
local SAMPLE_RATE = 24000
local BUFFER_SECONDS = 0.08
local REFERENCE_SPEED = 30
local MAX_SPEED = 70
local FADE_IN_START = 4
local FADE_IN_END = 9
local SPEED_EXPONENT = 2
local LEVEL = 0.15
local MAX_AMPLITUDE = 0.5
local BASE_CUTOFF = 120
local CUTOFF_PER_SPEED = 30
local COMMON_CUTOFF = 120
local COMMON_SHARE = 0.4
local AIR_SHARE = 0.08
local SIDE_GAIN = 0.35
local SIDE_CUTOFF = 0.5
local FRONT_CUTOFF = 0.25
local MIN_CUTOFF_SCALE = 0.4
local MAX_CUTOFF_SCALE = 1.5
local KNEE = 0.8
local FLUTTER_STROUHAL = 0.2
local FLUTTER_SIZE = 0.15
local FLUTTER_MIN_FREQUENCY = 12
local FLUTTER_MAX_FREQUENCY = 90
local FLUTTER_RADIUS = 0.92
local FLUTTER_START = 12
local FLUTTER_FULL = 40
local FLUTTER_DEPTH = 0.15
local FLUTTER_MAX = 1.8
local FLUTTER_AIR = 1.5
local FLUTTER_SIDE = 0.5
local GUST_DEPTH = 0.25
local GUST_INTERVAL = 0.2
local GUST_SMOOTHING = 0.3
local PARAMETER_SMOOTHING = 0.03
local VELOCITY_SMOOTHING = 0.05
local TELEPORT_SPEED = 1000
local SHELTER_RANGE = 20
local SHELTER_STRENGTH = 0.9
local SHELTER_INTERVAL = 0.1
local SHELTER_SMOOTHING = 0.4
local RMS_NORM = 3.5
pvars.StartGroup("Engine", "Audio", {prefix = "audio_"})
local volume = pvars.Setup2{
	key = "audio_ear_wind",
	default = 1,
	min = 0,
	friendly = "ear wind",
	help = "level of the wind in your ears when moving fast through the air, 0 turns it off",
}
pvars.EndGroup()
local parameter_k = 1 - math.exp(-1 / (PARAMETER_SMOOTHING * SAMPLE_RATE))
local gust_k = 1 - math.exp(-1 / (GUST_SMOOTHING * SAMPLE_RATE))
local common_k = 1 - math.exp(-2 * math.pi * COMMON_CUTOFF / SAMPLE_RATE)
local common_norm = RMS_NORM / math.sqrt(common_k)
local flutter_radius_squared = FLUTTER_RADIUS * FLUTTER_RADIUS
local ears = {}

for i = 1, 2 do
	ears[i] = {
		low_a = 0,
		low_b = 0,
		air = 0,
		gust = 1,
		gust_target = 1,
		until_gust = 0,
		amplitude = 0,
		cutoff = 500,
		target_amplitude = 0,
		target_cutoff = 500,
		flutter_a = 0,
		flutter_b = 0,
		flutter_frequency = FLUTTER_MIN_FREQUENCY,
		flutter_depth = 0,
		target_flutter_frequency = FLUTTER_MIN_FREQUENCY,
		target_flutter_depth = 0,
	}
end

local state = {seed = 7, common_a = 0, common_b = 0}

local function fill(data, from, count)
	local seed, common_a, common_b = state.seed, state.common_a, state.common_b

	for i = from, from + count - 1 do
		seed = (seed * 16807) % 2147483647
		common_a = common_a + (seed / 1073741823.5 - 1 - common_a) * common_k
		common_b = common_b + (common_a - common_b) * common_k
		local common = common_b * common_norm

		for c = 1, 2 do
			local ear = ears[c]
			seed = (seed * 16807) % 2147483647
			local white = seed / 1073741823.5 - 1
			ear.amplitude = ear.amplitude + (ear.target_amplitude - ear.amplitude) * parameter_k
			ear.cutoff = ear.cutoff + (ear.target_cutoff - ear.cutoff) * parameter_k
			local k = 1 - math.exp(-2 * math.pi * ear.cutoff / SAMPLE_RATE)
			ear.low_a = ear.low_a + (white - ear.low_a) * k
			ear.low_b = ear.low_b + (ear.low_a - ear.low_b) * k
			ear.air = ear.air + (white - ear.air) * math.min(k * 4, 1)
			ear.until_gust = ear.until_gust - 1

			if ear.until_gust <= 0 then
				seed = (seed * 16807) % 2147483647
				ear.gust_target = 1 + GUST_DEPTH * (seed / 1073741823.5 - 1)
				ear.until_gust = SAMPLE_RATE * GUST_INTERVAL
			end

			ear.gust = ear.gust + (ear.gust_target - ear.gust) * gust_k
			seed = (seed * 16807) % 2147483647
			ear.flutter_frequency = ear.flutter_frequency + (
					ear.target_flutter_frequency - ear.flutter_frequency
				) * parameter_k
			ear.flutter_depth = ear.flutter_depth + (ear.target_flutter_depth - ear.flutter_depth) * parameter_k
			local cosine = math.cos(2 * math.pi * ear.flutter_frequency / SAMPLE_RATE)
			local flutter = 2 * FLUTTER_RADIUS * cosine * ear.flutter_a - flutter_radius_squared * ear.flutter_b + (
					seed / 1073741823.5 - 1
				)
			ear.flutter_b = ear.flutter_a
			ear.flutter_a = flutter
			flutter = flutter / math.sqrt(
					(
							1 + flutter_radius_squared
						) / (
							3 * (
								1 - flutter_radius_squared
							) * (
								(
									1 + flutter_radius_squared
								) ^ 2 - 4 * flutter_radius_squared * cosine * cosine
							)
						)
				)
			local body = ear.low_b * RMS_NORM / math.sqrt(k) * math.min(math.max(0, 1 + ear.flutter_depth * flutter), FLUTTER_MAX)
			local air = (
					white - ear.air
				) * AIR_SHARE * math.min(math.max(0, 1 + ear.flutter_depth * FLUTTER_AIR * flutter), FLUTTER_MAX)
			local sample = (
					(
						1 - COMMON_SHARE
					) * body + COMMON_SHARE * common + air
				) * ear.amplitude * ear.gust
			local magnitude = math.abs(sample)

			if magnitude > KNEE then
				sample = (
						sample < 0 and
						-1 or
						1
					) * (
						KNEE + (
							1 - KNEE
						) * math.tanh((magnitude - KNEE) / (1 - KNEE))
					)
			end

			data[i * 2 + c - 1] = sample
		end
	end

	state.seed, state.common_a, state.common_b = seed, common_a, common_b
end

local sound
local previous_position
local shelter_time = 0
local shelter_target = 0
local sheltered = 0
local velocity = Vec3(0, 0, 0)

event.AddListener("Update", "ear_wind", function(dt)
	if not audio.initialized then return end

	if not sound then
		sound = audio.CreateStream(fill, BUFFER_SECONDS, SAMPLE_RATE, 2)
		sound:SetSpatial(false)
		sound:Play()
	end

	local position = audio.GetListenerPosition()
	local forward, up = audio.GetListenerOrientation()
	local left, right = ears[1], ears[2]

	if not position or not forward or dt <= 0 then
		left.target_amplitude, right.target_amplitude = 0, 0
		return
	end

	if previous_position then
		local step = (position - previous_position) / dt
		velocity = step:GetLength() > TELEPORT_SPEED and
			Vec3(0, 0, 0) or
			velocity + (
				step - velocity
			) * (
				1 - math.exp(-dt / VELOCITY_SMOOTHING)
			)
	end

	previous_position = position:Copy()
	shelter_time = shelter_time - dt

	if shelter_time <= 0 then
		shelter_time = SHELTER_INTERVAL
		shelter_target = shelter.GetAgainst(position, audio.wind, SHELTER_RANGE, players.GetLocal())
	end

	sheltered = sheltered + (
			shelter_target - sheltered
		) * (
			1 - math.exp(-dt / SHELTER_SMOOTHING)
		)
	local air = audio.medium_velocity * (1 - SHELTER_STRENGTH * sheltered) - velocity
	local length = air:GetLength()

	if length ~= length then
		left.target_amplitude, right.target_amplitude = 0, 0
		return
	end

	local speed = math.min(length, MAX_SPEED)
	local growth = LEVEL * (speed / REFERENCE_SPEED) ^ SPEED_EXPONENT
	local amplitude = growth / (
			1 + growth / MAX_AMPLITUDE
		) * math.smoothstep(FADE_IN_START, FADE_IN_END, speed) * volume:Get()
	local cutoff = BASE_CUTOFF + CUTOFF_PER_SPEED * speed

	if length < 0.1 then
		left.target_amplitude, right.target_amplitude = 0, 0
		return
	end

	local from = air * (-1 / length)
	local side = from:GetDot(forward:GetCross(up))
	local front = from:GetDot(forward)

	for c = 1, 2 do
		local ear = ears[c]
		local windward = c == 2 and side or -side
		ear.target_amplitude = amplitude * (1 + SIDE_GAIN * windward)
		ear.target_flutter_frequency = math.clamp(
			FLUTTER_STROUHAL * speed / FLUTTER_SIZE,
			FLUTTER_MIN_FREQUENCY,
			FLUTTER_MAX_FREQUENCY
		)
		ear.target_flutter_depth = FLUTTER_DEPTH * math.smoothstep(FLUTTER_START, FLUTTER_FULL, speed) * (
				1 + FLUTTER_SIDE * windward
			)
		ear.target_cutoff = cutoff * math.clamp(
				(1 + SIDE_CUTOFF * windward) * (1 + FRONT_CUTOFF * front),
				MIN_CUTOFF_SCALE,
				MAX_CUTOFF_SCALE
			)
	end
end)
