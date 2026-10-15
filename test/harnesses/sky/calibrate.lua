-- finds the engine's three channel coefficients (Rayleigh, ozone, aerosol per channel) that reproduce the spectral
-- Monte Carlo sky (spectral.lua) in linear sRGB, so the rgb approximation of the spectrum is as good as three
-- channels get. The engine's own approximations (multiple scattering LUT) are not part of this, both sides are
-- path traced.
-- AOD=0.1 ALPHA=1.3 SSA=0.95 G=0.7 PATHS=3000 ITERS=150 luajit glw --cli lua "import('test/harnesses/sky/calibrate.lua')"
local mc = import("test/harnesses/sky/mc.lua")
local spectral = import("test/harnesses/sky/spectral.lua")
local aerosol = {
	aod = tonumber(os.getenv("AOD") or "0.1"),
	alpha = tonumber(os.getenv("ALPHA") or "1.3"),
	ssa = tonumber(os.getenv("SSA") or "0.95"),
	g = tonumber(os.getenv("G") or "0.7"),
	h = 1.2,
}
local paths = tonumber(os.getenv("PATHS") or "3000")
local ground = 0.26
local E_SUN = 127000
local suns = {60, 30, 10}
local SAMPLES = {{90, 0}, {90, 90}, {60, 180}, {45, 0}, {45, 90}, {45, 180}, {30, 90}, {30, 180}, {15, 0}, {15, 90}, {15, 180}, {5, 90}, {5, 180}, {1, 90}, {1, 180}}
local points = {}

math.randomseed(777)

for _, sun_elev in ipairs(suns) do
	local se = math.rad(sun_elev)
	local sun = {math.cos(se), math.sin(se), 0}

	for _, s in ipairs(SAMPLES) do
		local el, az = math.rad(s[1]), math.rad(s[2])
		local dir = {math.cos(el) * math.cos(az), math.sin(el), math.cos(el) * math.sin(az)}
		local gamma = math.deg(math.acos(math.max(-1, math.min(1, dir[1] * sun[1] + dir[2] * sun[2] + dir[3] * sun[3]))))

		if gamma > 12 then
			local r, g, b = spectral.Radiance(sun, dir, aerosol, paths * 2, ground, E_SUN)
			points[#points + 1] = {sun = sun, dir = dir, truth = {r, g, b}, name = string.format("sun %2g el %2g az %3g", sun_elev, s[1], s[2])}
		end
	end
end

print(#points .. " reference points")
-- p: {rayleigh = {3}, ozone = {3}, mie = {3}}
local function evaluate(p, verbose)
	math.randomseed(4242)
	local err, n = 0, 0
	local sum_c = {0, 0, 0}

	for _, pt in ipairs(points) do
		local out = {}

		for c = 1, 3 do
			out[c] = mc.Radiance(
				{
					rayleigh = p.rayleigh[c],
					ozone = p.ozone[c],
					mie_ext = p.mie[c],
					mie_sca = p.mie[c] * aerosol.ssa,
					albedo = ground,
					g = aerosol.g,
					h = aerosol.h,
				},
				pt.sun[1],
				pt.sun[2],
				pt.sun[3],
				pt.dir[1],
				pt.dir[2],
				pt.dir[3],
				paths,
				100,
				E_SUN
			)
			local l = math.log(out[c] / pt.truth[c])
			err = err + l * l
			sum_c[c] = sum_c[c] + l
		end

		n = n + 1

		if verbose then
			print(string.format("  %-20s rgb ratio %.3f %.3f %.3f", pt.name, out[1] / pt.truth[1], out[2] / pt.truth[2], out[3] / pt.truth[3]))
		end
	end

	if verbose then print(string.format("  mean log ratio per channel %.3f %.3f %.3f", sum_c[1] / n, sum_c[2] / n, sum_c[3] / n)) end

	return math.sqrt(err / (3 * n))
end

local current = {rayleigh = {0.0058, 0.0135, 0.0331}, ozone = {0.00065, 0.00188, 0.000085}, mie = {0.0517, 0.0517, 0.0517}}
-- the engine's aerosol at this optical depth: ext = aod / (h + 0.07 * 8)
local mie_550 = aerosol.aod / (aerosol.h + 0.07 * 8)
current.mie = {mie_550 * (680 / 550) ^ -aerosol.alpha, mie_550, mie_550 * (440 / 550) ^ -aerosol.alpha}
print(string.format("current engine rgb constants with the same aerosol: rms log error %.3f", evaluate(current, true)))
local scale_only = {rayleigh = {0.0058, 0.0135, 0.0331}, ozone = current.ozone, mie = current.mie}

local function pack(p)
	local x = {}

	for c = 1, 3 do
		x[c] = math.log(p.rayleigh[c])
		x[3 + c] = math.log(p.ozone[c])
		x[6 + c] = math.log(p.mie[c])
	end

	return x
end

local function unpack_x(x)
	local p = {rayleigh = {}, ozone = {}, mie = {}}

	for c = 1, 3 do
		p.rayleigh[c] = math.exp(x[c])
		p.ozone[c] = math.exp(x[3 + c])
		p.mie[c] = math.exp(x[6 + c])
	end

	return p
end

local function f(x)
	return evaluate(unpack_x(x))
end

local n = 9
local x0 = pack(current)
local simplex = {{x = x0, f = f(x0)}}

for k = 1, n do
	local x = {table.unpack(x0)}
	x[k] = x[k] + 0.2
	simplex[k + 1] = {x = x, f = f(x)}
end

local function sort()
	table.sort(simplex, function(a, b)
		return a.f < b.f
	end)
end

for iter = 1, tonumber(os.getenv("ITERS") or "150") do
	sort()
	local c = {}

	for k = 1, n do
		local s = 0

		for j = 1, n do
			s = s + simplex[j].x[k]
		end

		c[k] = s / n
	end

	local worst = simplex[n + 1]

	local function along(t)
		local x = {}

		for k = 1, n do
			x[k] = c[k] + t * (worst.x[k] - c[k])
		end

		return x
	end

	local xr = along(-1)
	local fr = f(xr)

	if fr < simplex[1].f then
		local xe = along(-2)
		local fe = f(xe)
		simplex[n + 1] = fe < fr and {x = xe, f = fe} or {x = xr, f = fr}
	elseif fr < simplex[n].f then
		simplex[n + 1] = {x = xr, f = fr}
	else
		local xc = along(fr < worst.f and -0.5 or 0.5)
		local fc = f(xc)

		if fc < math.min(fr, worst.f) then
			simplex[n + 1] = {x = xc, f = fc}
		else
			for j = 2, n + 1 do
				for k = 1, n do
					simplex[j].x[k] = simplex[1].x[k] + 0.5 * (simplex[j].x[k] - simplex[1].x[k])
				end

				simplex[j].f = f(simplex[j].x)
			end
		end
	end

	if iter % 25 == 0 then
		sort()
		print(string.format("iter %d best rms log %.4f", iter, simplex[1].f))
	end
end

sort()
local best = unpack_x(simplex[1].x)
print(string.format("RAYLEIGH_BETA = vec3(%.5f, %.5f, %.5f)", best.rayleigh[1], best.rayleigh[2], best.rayleigh[3]))
print(string.format("OZONE_BETA_ABS = vec3(%.6f, %.6f, %.6f)", best.ozone[1], best.ozone[2], best.ozone[3]))
print(string.format("mie extinction rgb %.5f %.5f %.5f (aod %.2f, alpha %.1f)", best.mie[1], best.mie[2], best.mie[3], aerosol.aod, aerosol.alpha))
print(string.format("fitted rms log error %.4f", evaluate(best, true)))
os.exit(0)
