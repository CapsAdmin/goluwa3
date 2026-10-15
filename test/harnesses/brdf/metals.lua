-- Schlick (what ibl.lua's F_Schlick does for a metal: F0 = albedo, white grazing reflectance) and the F82 tint model
-- (Hoffman 2023, Kutz and Hoffman, the Adobe standard material) against the exact unpolarised Fresnel equations of
-- a conductor, with the complex index of refraction n + ik per rgb channel. n and k are the usual rgb fits (pbrt / mitsuba
-- tables), good enough for the shape of the curve, not a spectral measurement.
-- luajit test/harnesses/brdf/metals.lua
local metals = {
	gold = {n = {0.143, 0.375, 1.442}, k = {3.983, 2.386, 1.603}},
	copper = {n = {0.200, 0.924, 1.102}, k = {3.912, 2.452, 2.142}},
	aluminium = {n = {1.657, 0.880, 0.521}, k = {9.224, 6.270, 4.837}},
	silver = {n = {0.155, 0.116, 0.138}, k = {4.828, 3.122, 2.147}},
	iron = {n = {2.912, 2.949, 2.585}, k = {3.077, 2.934, 2.756}},
}
local order = {"gold", "copper", "aluminium", "silver", "iron"}

-- complex numbers as {re, im}
local function cmul(a, b) return {a[1] * b[1] - a[2] * b[2], a[1] * b[2] + a[2] * b[1]} end
local function cdiv(a, b)
	local d = b[1] * b[1] + b[2] * b[2]
	return {(a[1] * b[1] + a[2] * b[2]) / d, (a[2] * b[1] - a[1] * b[2]) / d}
end
local function csub(a, b) return {a[1] - b[1], a[2] - b[2]} end
local function cadd(a, b) return {a[1] + b[1], a[2] + b[2]} end
local function csqrt(a)
	local r = math.sqrt(a[1] * a[1] + a[2] * a[2])
	local re = math.sqrt(math.max((r + a[1]) / 2, 0))
	local im = math.sqrt(math.max((r - a[1]) / 2, 0))
	return {re, a[2] < 0 and -im or im}
end
local function cabs2(a) return a[1] * a[1] + a[2] * a[2] end

local function fresnel_conductor(cos_i, n, k)
	local eta = {n, k}
	local sin2 = 1 - cos_i * cos_i
	local cos_t = csqrt(csub({1, 0}, cdiv({sin2, 0}, cmul(eta, eta))))
	local ci = {cos_i, 0}
	local rs = cdiv(csub(ci, cmul(eta, cos_t)), cadd(ci, cmul(eta, cos_t)))
	local rp = cdiv(csub(cmul(eta, ci), cos_t), cadd(cmul(eta, ci), cos_t))
	return 0.5 * (cabs2(rs) + cabs2(rp))
end

local function f0_of(n, k)
	return ((n - 1) ^ 2 + k * k) / ((n + 1) ^ 2 + k * k)
end

local function schlick(f0, mu)
	return f0 + (1 - f0) * (1 - mu) ^ 5
end

-- F82 tint: Schlick minus a dip that makes the curve pass through f82 at 82 degrees (mu = 1 / 7)
local MU_BAR = 1 / 7
local function f82_tint(f0, f82, mu)
	local a = (schlick(f0, MU_BAR) - f82) / (MU_BAR * (1 - MU_BAR) ^ 6)
	return schlick(f0, mu) - a * mu * (1 - mu) ^ 6
end

local angles = {0, 30, 50, 60, 70, 75, 80, 82, 85, 88}
local worst_schlick = 0

for _, name in ipairs(order) do
	local m = metals[name]
	local f0, f82 = {}, {}

	for c = 1, 3 do
		f0[c] = f0_of(m.n[c], m.k[c])
		f82[c] = fresnel_conductor(math.cos(math.rad(82)), m.n[c], m.k[c])
	end

	print(string.format("%s  F0 %.3f %.3f %.3f   exact at 82 degrees %.3f %.3f %.3f   schlick at 82 %.3f %.3f %.3f", name, f0[1], f0[2], f0[3], f82[1], f82[2], f82[3], schlick(f0[1], MU_BAR), schlick(f0[2], MU_BAR), schlick(f0[3], MU_BAR)))
	print("  angle   exact rgb                 schlick rgb (error)                   f82 tint rgb (error)")

	for _, a in ipairs(angles) do
		local mu = math.cos(math.rad(a))
		local e, s, t, se, te = {}, {}, {}, {}, {}

		for c = 1, 3 do
			e[c] = fresnel_conductor(mu, m.n[c], m.k[c])
			s[c] = schlick(f0[c], mu)
			t[c] = f82_tint(f0[c], f82[c], mu)
			se[c] = s[c] - e[c]
			te[c] = t[c] - e[c]
			worst_schlick = math.max(worst_schlick, math.abs(se[c]) / e[c])
		end

		print(string.format("  %2d     %.3f %.3f %.3f     %.3f %.3f %.3f (%+.3f %+.3f %+.3f)     %.3f %.3f %.3f (%+.3f %+.3f %+.3f)", a, e[1], e[2], e[3], s[1], s[2], s[3], se[1], se[2], se[3], t[1], t[2], t[3], te[1], te[2], te[3]))
	end
end

print(string.format("\nworst relative error of schlick over the table: %.1f percent", worst_schlick * 100))

-- what a lit surface shows: the directional albedo of the GGX lobe (a white light from everywhere, Smith G1 for the
-- light, importance sampled half vectors), exact Fresnel against Schlick, per view angle and roughness
local function albedo(fresnel, rough, nov)
	local a = rough * rough
	local n = 4000
	local sum = 0
	local sin_v = math.sqrt(1 - nov * nov)

	for i = 0, n - 1 do
		local u1 = (i + 0.5) / n
		local u2 = (i * 0.6180339887) % 1
		local cos_h = math.sqrt((1 - u1) / (1 + (a * a - 1) * u1))
		local sin_h = math.sqrt(1 - cos_h * cos_h)
		local phi = 2 * math.pi * u2
		-- v in the x z plane, h at (phi) around the normal
		local voh = sin_v * sin_h * math.cos(phi) + nov * cos_h
		local nol = 2 * voh * cos_h - nov

		if voh > 0 and nol > 0 then
			local g1 = 2 * nol / (nol + math.sqrt(a * a + (1 - a * a) * nol * nol))
			sum = sum + fresnel(voh) * g1 * voh / (nov * cos_h)
		end
	end

	return sum / n
end

print("\ndirectional albedo of the specular lobe, schlick over exact (green channel, 1 is exact)")
print("metal      roughness   n.v 0.1   0.2     0.4     0.7")

for _, name in ipairs(order) do
	local m = metals[name]
	local f0 = f0_of(m.n[2], m.k[2])

	for _, rough in ipairs{0.15, 0.4, 0.7} do
		local row = {}

		for _, nov in ipairs{0.1, 0.2, 0.4, 0.7} do
			local exact = albedo(function(c) return fresnel_conductor(c, m.n[2], m.k[2]) end, rough, nov)
			local approx = albedo(function(c) return schlick(f0, c) end, rough, nov)
			row[#row + 1] = string.format("%.3f", approx / exact)
		end

		print(string.format("%-10s %.2f        %s", name, rough, table.concat(row, "   ")))
	end
end
