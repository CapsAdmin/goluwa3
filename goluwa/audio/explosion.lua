local ffi = require("ffi")
local explosion = {}
explosion.REFERENCE_PRESSURE = 20e-6
explosion.AMBIENT_PRESSURE = 101325
explosion.DECAY = 1.2
explosion.NEGATIVE_RATIO = 3.5
explosion.SHOCK_RISE_SAMPLES = 2
explosion.CRACKLE_LEVEL = 0.12
explosion.CRACKLE_TIME = 0.012
explosion.FIREBALL_LEVEL = 0.22
explosion.FIREBALL_TIME = 0.12
explosion.FIREBALL_CORNER = 90
explosion.DEBRIS_RATE = 70
explosion.DEBRIS_TIME = 0.6
explosion.DEBRIS_LEVEL = 0.03
explosion.DURATION = 2.2
local float_array_t = ffi.typeof("float[?]")

-- Kinney and Graham: peak overpressure (Pa) and positive phase duration (s) of the blast wave of a TNT charge at a distance
function explosion.GetBlast(charge_kg, distance)
	local scale = charge_kg ^ (1 / 3)
	local z = distance / scale
	local numerator = 808 * (1 + (z / 4.5) ^ 2)
	local denominator = math.sqrt(1 + (z / 0.048) ^ 2) * math.sqrt(1 + (z / 0.32) ^ 2) * math.sqrt(1 + (z / 1.35) ^ 2)
	local overpressure = explosion.AMBIENT_PRESSURE * numerator / denominator
	local duration = 980 * (
			1 + (
				z / 0.54
			) ^ 10
		) / (
			(
				1 + (
					z / 0.02
				) ^ 3
			) * (
				1 + (
					z / 0.74
				) ^ 6
			) * math.sqrt(1 + (z / 6.9) ^ 2)
		) * scale / 1000
	return overpressure, duration
end

function explosion.GetPeakLevel(overpressure)
	return 20 * math.log10(overpressure / explosion.REFERENCE_PRESSURE)
end

-- a dry pressure signature as heard at `distance` from a charge: the Friedlander wave of the shock and its negative phase, the crackle of the turbulent fireball, its low thump, and the debris coming down. Peak normalized to 1, the overpressure of the shock is returned so the level can be set from it. Everything after it (air, ground, reverb) is the engine's
function explosion.Generate(charge_kg, distance, sample_rate, seed)
	local random = math.random
	math.randomseed(seed or 1)
	local overpressure, duration = explosion.GetBlast(charge_kg, distance)
	local count = math.floor(explosion.DURATION * sample_rate)
	local out = float_array_t(count)
	local decay = explosion.DECAY
	local negative_time = duration * explosion.NEGATIVE_RATIO

	for i = 0, count - 1 do
		local t = i / sample_rate
		local value = 0

		if t < duration * 12 then
			local x = t / duration
			value = (1 - x) * math.exp(-decay * x)

			if x > 1 then
				-- the negative phase is shallower and longer, so it carries as much impulse as the positive one
				local n = (t - duration) / negative_time
				value = value * 0.35 + (-0.18 * n * math.exp(-n))
			end
		end

		out[i] = value
	end

	for i = 0, explosion.SHOCK_RISE_SAMPLES - 1 do
		out[i] = out[i] * (i + 1) / (explosion.SHOCK_RISE_SAMPLES + 1)
	end

	-- crackle: broadband turbulence of the fireball, brighter than the shock itself
	local low_pass = 0
	local fireball_coefficient = 1 - math.exp(-2 * math.pi * explosion.FIREBALL_CORNER / sample_rate)
	local previous = 0

	for i = 0, count - 1 do
		local t = i / sample_rate
		local white = random() * 2 - 1
		local band = white - previous * 0.6
		previous = white
		low_pass = low_pass + fireball_coefficient * (random() * 2 - 1 - low_pass)
		local crackle = band * explosion.CRACKLE_LEVEL * math.exp(-t / explosion.CRACKLE_TIME)
		local thump = low_pass * explosion.FIREBALL_LEVEL * 6 * (
				1 - math.exp(-t / 0.008)
			) * math.exp(-t / explosion.FIREBALL_TIME)
		out[i] = out[i] + crackle + thump
	end

	-- debris: bursts at a rate that decays with time
	local t = 0.04

	while t < explosion.DURATION - 0.05 do
		t = t - math.log(1 - random()) / (
				explosion.DEBRIS_RATE * math.exp(-t / explosion.DEBRIS_TIME)
			)
		local start = math.floor(t * sample_rate)
		local level = explosion.DEBRIS_LEVEL * math.exp(-t / explosion.DEBRIS_TIME) * math.exp((random() - 0.5) * 2.5)
		local length = math.floor((0.002 + random() * 0.004) * sample_rate)

		for k = 0, length - 1 do
			if start + k < count then
				out[start + k] = out[start + k] + level * (random() * 2 - 1) * math.exp(-k / (length * 0.4))
			end
		end
	end

	-- no net pressure: a first order high pass at 8 Hz
	local previous_in, previous_out = 0, 0
	local pole = math.exp(-2 * math.pi * 8 / sample_rate)

	for i = 0, count - 1 do
		local x = out[i]
		previous_out = pole * (previous_out + x - previous_in)
		previous_in = x
		out[i] = previous_out
	end

	local peak = 0

	for i = 0, count - 1 do
		peak = math.max(peak, math.abs(out[i]))
	end

	for i = 0, count - 1 do
		out[i] = out[i] / peak
	end

	return out, count, overpressure, duration
end

return explosion
