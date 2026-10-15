-- Spectral reference sky: the Monte Carlo of mc.lua run at 21 wavelengths with physical coefficients, folded to
-- CIE XYZ and to linear sRGB, white balanced so the sun above the atmosphere is white like the engine's sun.
-- Rayleigh: Hansen and Travis / Bodhaine optical depth. Ozone: a gaussian fit to the Chappuis band (peak 5.1e-21 cm2
-- at 603 nm, 300 DU). Aerosol: optical depth at 550 nm with an Angstrom exponent, constant single scattering albedo and
-- asymmetry, the engine's height profile.
local mc = import("test/harnesses/sky/mc.lua")
local spectral = {}
local LAMBDAS = {}

for l = 380, 780, 20 do
	LAMBDAS[#LAMBDAS + 1] = l
end

local DLAMBDA = 20

local function lobe(l, mu, s1, s2)
	local t = (l - mu) / (l < mu and s1 or s2)
	return math.exp(-0.5 * t * t)
end

-- Wyman, Sloan and Shirley 2013 multi lobe fit of the CIE 1931 observer
local function cmf(l)
	local x = 1.056 * lobe(l, 599.8, 37.9, 31.0) + 0.362 * lobe(l, 442.0, 16.0, 26.7) - 0.065 * lobe(l, 501.1, 20.4, 26.2)
	local y = 0.821 * lobe(l, 568.8, 46.9, 40.5) + 0.286 * lobe(l, 530.9, 16.3, 31.1)
	local z = 1.217 * lobe(l, 437.0, 11.8, 36.0) + 0.681 * lobe(l, 459.0, 26.0, 13.8)
	return x, y, z
end

local function planck(l_nm, T)
	local l = l_nm * 1e-9
	return 1 / (l ^ 5 * (math.exp(1.4388e-2 / (l * T)) - 1))
end

local function rayleigh_tau(l_nm)
	local l = l_nm / 1000
	return 0.008569 * l ^ -4 * (1 + 0.0113 * l ^ -2 + 0.00013 * l ^ -4)
end

local OZONE_COLUMN = 8.06e18
local OZONE_HEIGHT_KM = 15

local function ozone_beta_peak(l_nm)
	local sigma = 5.1e-21 * math.exp(-0.5 * ((l_nm - 603) / 58) ^ 2)
	return sigma * OZONE_COLUMN / OZONE_HEIGHT_KM
end

local function srgb(X, Y, Z)
	return 3.2404542 * X - 1.5371385 * Y - 0.4985314 * Z, -0.9692660 * X + 1.8760108 * Y + 0.0415560 * Z, 0.0556434 * X - 0.2040259 * Y + 1.0572252 * Z
end

-- the sun's spectrum normalised so that its luminance above the atmosphere is sun_illuminance
local function sun_spectrum(sun_illuminance)
	local norm = 0

	for _, l in ipairs(LAMBDAS) do
		local _, y = cmf(l)
		norm = norm + planck(l, 5778) * y * DLAMBDA
	end

	local E = {}

	for i, l in ipairs(LAMBDAS) do
		E[i] = sun_illuminance * planck(l, 5778) / norm
	end

	return E
end

-- aerosol = {aod, alpha, ssa, g, h}, returns the linear sRGB radiance (white balanced to the sun) and its luminance
function spectral.Radiance(sun, view, aerosol, paths, ground_albedo, sun_illuminance, max_order)
	local E = sun_spectrum(sun_illuminance)
	local X, Y, Z = 0, 0, 0
	local sx, sy, sz = 0, 0, 0

	for i, l in ipairs(LAMBDAS) do
		local x, y, z = cmf(l)
		sx, sy, sz = sx + E[i] * x * DLAMBDA, sy + E[i] * y * DLAMBDA, sz + E[i] * z * DLAMBDA
		local ext_550 = aerosol.aod / (aerosol.h + 0.07 * 8)
		local ext = ext_550 * (l / 550) ^ -aerosol.alpha
		local L = mc.Radiance(
			{
				rayleigh = rayleigh_tau(l) / 8,
				ozone = ozone_beta_peak(l),
				mie_ext = ext,
				mie_sca = ext * aerosol.ssa,
				albedo = ground_albedo,
				g = aerosol.g,
				h = aerosol.h,
				fog = aerosol.fog,
			},
			sun[1],
			sun[2],
			sun[3],
			view[1],
			view[2],
			view[3],
			paths,
			max_order or 100,
			E[i]
		)
		X, Y, Z = X + L * x * DLAMBDA, Y + L * y * DLAMBDA, Z + L * z * DLAMBDA
	end

	local r, g, b = srgb(X, Y, Z)
	local wr, wg, wb = srgb(sx, sy, sz)
	-- von Kries in rgb: the sun above the atmosphere has equal channels, each of them its luminance
	local lum_sun = sy
	return r * lum_sun / wr, g * lum_sun / wg, b * lum_sun / wb
end

return spectral
