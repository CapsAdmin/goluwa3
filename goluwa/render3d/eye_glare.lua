local eye_glare = {}
eye_glare.CHANNEL_WAVELENGTH = {611, 549, 464}
eye_glare.REFERENCE_WAVELENGTH = 560
local PIGMENTATION = 0.5
local SCATTER_EXPONENT = -4
local BAND_STEPS = 24

function eye_glare.GetSpread(degrees, wavelength_ratio)
	local scaled = degrees / wavelength_ratio
	local core = (
			9.2e6 / (
				1 + (
					scaled / 0.0046
				) ^ 2
			) ^ 1.5 + 1.5e5 / (
				1 + (
					scaled / 0.045
				) ^ 2
			) ^ 1.5
		) / wavelength_ratio ^ 2
	local scatter = 400 / (1 + (degrees / 0.1) ^ 2) + 3e-8 * degrees ^ 2
	local pigment = 1300 / (1 + (degrees / 0.1) ^ 2) ^ 1.5 + 0.8 / (1 + (degrees / 0.1) ^ 2) ^ 0.5
	return core + scatter * wavelength_ratio ^ SCATTER_EXPONENT + PIGMENTATION * (
			pigment + 2.5e-3
		)
end

function eye_glare.GetBandEnergy(low, high, wavelength_ratio)
	local step = (high - low) / BAND_STEPS
	local energy = 0

	for i = 0, BAND_STEPS - 1 do
		local degrees = 2 ^ (low + (i + 0.5) * step)
		local radians = math.rad(degrees)
		energy = energy + eye_glare.GetSpread(degrees, wavelength_ratio) * 2 * math.pi * radians * radians * step * math.log(2)
	end

	return energy
end

return eye_glare
