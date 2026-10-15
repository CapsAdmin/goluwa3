-- the sun's absolute intensity. 1) the luminous efficacy of a 5778 K blackbody with the solar constant, the illuminance
-- above the atmosphere (the engine's 127000 lux), 2) the direct beam at the ground per sun elevation, the engine's rgb
-- transmittance times the sun colour (luminance) against the spectral integral of the same atmosphere (Rayleigh, ozone,
-- aerosol, 21 wavelengths) folded with the CIE photopic curve.
-- luajit glw --2d --one-frame --background lua "import('test/harnesses/sky/sun.lua')"
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local system = import("goluwa/system.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local R_PLANET, R_ATMOSPHERE = 6371.0, 6471.0
local EYE = 1.75 * 0.001

local function lobe(l, mu, s1, s2)
	local t = (l - mu) / (l < mu and s1 or s2)
	return math.exp(-0.5 * t * t)
end

-- Wyman, Sloan and Shirley 2013 fit of the CIE 1931 y
local function ybar(l)
	return 0.821 * lobe(l, 568.8, 46.9, 40.5) + 0.286 * lobe(l, 530.9, 16.3, 31.1)
end

local function cmf(l)
	local x = 1.056 * lobe(l, 599.8, 37.9, 31.0) + 0.362 * lobe(l, 442.0, 16.0, 26.7) - 0.065 * lobe(l, 501.1, 20.4, 26.2)
	local z = 1.217 * lobe(l, 437.0, 11.8, 36.0) + 0.681 * lobe(l, 459.0, 26.0, 13.8)
	return x, ybar(l), z
end

local function srgb(X, Y, Z)
	return 3.2404542 * X - 1.5371385 * Y - 0.4985314 * Z, -0.9692660 * X + 1.8760108 * Y + 0.0415560 * Z, 0.0556434 * X - 0.2040259 * Y + 1.0572252 * Z
end

local function planck(l_nm, T)
	local l = l_nm * 1e-9
	return 1 / (l ^ 5 * (math.exp(1.4388e-2 / (l * T)) - 1))
end

local function rayleigh_tau(l_nm)
	local l = l_nm / 1000
	return 0.008569 * l ^ -4 * (1 + 0.0113 * l ^ -2 + 0.00013 * l ^ -4)
end

local function ozone_beta_peak(l_nm)
	return 5.1e-21 * math.exp(-0.5 * ((l_nm - 603) / 58) ^ 2) * 8.06e18 / 15
end

-- 1) efficacy of the sun above the atmosphere
local total, visible = 0, 0

for l = 100, 20000, 10 do
	local b = planck(l, 5778)
	total = total + b * 10
	visible = visible + b * ybar(l) * 10
end

local efficacy = 683 * visible / total
print(string.format("5778 K blackbody: luminous efficacy %.1f lm/W, with the solar constant 1361 W/m2: %.0f lux (the engine: %d)", efficacy, efficacy * 1361, atmosphere.GetSunIlluminance()))

-- 2) the direct beam
local ext_550 = math.max(-math.log(0.02) / (atmosphere.GetAerosolVisibility() / 1000) - 0.0135, 0)
local ANGSTROM = 1.3

local function densities(radius)
	local alt = math.max(radius - R_PLANET, 0)
	return math.exp(-alt / 8), math.exp(-alt / 1.2) + 0.07 * math.exp(-alt / 8), math.max(0, 1 - math.abs(radius - R_PLANET - 25) / 15)
end

local function optical_depths(elev)
	local dx, dy = math.cos(elev), math.sin(elev)
	local x, y = 0, R_PLANET + EYE
	local b = x * dx + y * dy
	local c = x * x + y * y - R_ATMOSPHERE ^ 2
	local top = -b + math.sqrt(b * b - c)
	local n, ds = 400, top / 400
	local r, m, o = 0, 0, 0

	for i = 0, n - 1 do
		local t = (i + 0.5) * ds
		local dr, dm, do_ = densities(math.sqrt((x + dx * t) ^ 2 + (y + dy * t) ^ 2))
		r, m, o = r + dr * ds, m + dm * ds, o + do_ * ds
	end

	return r, m, o
end

local TOA = atmosphere.GetSunIlluminance()
local norm = 0

for l = 380, 780, 10 do
	norm = norm + planck(l, 5778) * ybar(l)
end

print("\nelevation   direct normal illuminance: spectral   engine (rgb transmittance x sun colour)   engine / spectral      engine horizontal  (rgb)")

for _, deg in ipairs{90, 60, 45, 30, 20, 10, 5, 2, 1} do
	local elev = math.rad(deg)
	local r, m, o = optical_depths(elev)
	local spectral = 0
	local X, Y, Z = 0, 0, 0

	for l = 380, 780, 10 do
		local tau = rayleigh_tau(l) / 8 * r + ext_550 * (l / 550) ^ -ANGSTROM * m + ozone_beta_peak(l) * o
		local x, y, z = cmf(l)
		local w = planck(l, 5778) * math.exp(-tau)
		spectral = spectral + w * y
		X, Y, Z = X + w * x, Y + w * y, Z + w * z
	end

	local sr, sg, sb = srgb(X, Y, Z)
	local sy = 0.2126 * sr + 0.7152 * sg + 0.0722 * sb

	spectral = TOA * spectral / norm
	local T = atmosphere.GetTransmittance(Vec3(math.cos(elev), math.sin(elev), 0))
	local C = atmosphere.SUN_COLOR
	local er, eg, eb = TOA * T.x * C.x, TOA * T.y * C.y, TOA * T.z * C.z
	local engine = 0.2126 * er + 0.7152 * eg + 0.0722 * eb
	print(string.format("    colour (rgb / luminance)  spectral %.3f %.3f %.3f   engine %.3f %.3f %.3f", sr / sy, sg / sy, sb / sy, er / engine, eg / engine, eb / engine))
	print(string.format("%3d         %8.0f        %8.0f        %.3f        %8.0f   (%.0f %.0f %.0f)", deg, spectral, engine, engine / spectral, engine * math.sin(elev), er * math.sin(elev), eg * math.sin(elev), eb * math.sin(elev)))
end

system.ShutDown(0)
