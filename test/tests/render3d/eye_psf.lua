local T = import("test/environment.lua")
local eye_psf = import("goluwa/render3d/eye_psf.lua")
local eye_glare = import("goluwa/render3d/eye_glare.lua")

T.Test("eye psf of a plain pupil has its first dark ring at the Airy radius", function()
	local grid = eye_psf.GRID
	local power = eye_psf.BuildSpectrum(true)
	local half = grid / 2
	local per_texel = eye_psf.GetDegreesPerTexel()
	local airy = math.deg(1.22 * eye_glare.REFERENCE_WAVELENGTH * 1e-9 / eye_psf.PUPIL_DIAMETER)
	local best, best_value = 0, math.huge

	for texel = math.floor(airy / per_texel * 0.6), math.floor(airy / per_texel * 1.4) do
		local value = power[half * grid + half + texel]

		if value < best_value then best, best_value = texel, value end
	end

	T(best * per_texel)["~"](airy, per_texel)
	T(power[half * grid + half] > power[half * grid + half + 8] * 50)["=="](true)
end)

T.Test("eye psf modulation keeps each ring at mean one and shows spikes", function()
	local modulation = eye_psf.BuildModulation(eye_psf.BuildSpectrum(false))
	local peak = 0

	for ir = 0, eye_psf.RADII - 1 do
		local sum = 0

		for ia = 0, eye_psf.ANGLES - 1 do
			local value = modulation[ir * eye_psf.ANGLES + ia]
			sum = sum + value
			peak = math.max(peak, value)
		end

		T(sum / eye_psf.ANGLES)["~"](1, 1e-4)
	end

	T(peak > 4)["=="](true)
end)
