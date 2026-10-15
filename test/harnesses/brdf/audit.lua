-- numerical audit of the direct light BRDF (before the 2026-10-15 fixes: the Burley diffuse and the missing energy compensation, see the columns) (goluwa/render3d/ibl.lua, surface_lighting.lua), evaluated with the same
-- formulas in plain lua: directional albedo (the share of the light a surface sends back, for a white diffuse and a white
-- metal) against what a physical surface may send back (at most 1), and Schlick against the exact Fresnel equations.
-- luajit test/harnesses/brdf/audit.lua
local PI = math.pi
local sqrt, max, min, cos, sin = math.sqrt, math.max, math.min, math.cos, math.sin

local function pow5(x)
	local x2 = x * x
	return x2 * x2 * x
end

local function D_ggx(alpha, noh)
	local a2 = alpha * alpha
	local d = noh * noh * (a2 - 1) + 1
	return a2 / (PI * d * d)
end

-- surface_lighting's V (height correlated smith), with the same clamp of alpha^2
local function V_smith(alpha, nov, nol)
	local a2 = max(alpha * alpha, 1e-3)
	local lv = nol * sqrt((nov - a2 * nov) * nov + a2)
	local ll = nov * sqrt((nol - a2 * nol) * nol + a2)
	return 0.5 / (lv + ll)
end

local function F_schlick(f0, voh)
	return f0 + (1 - f0) * pow5(1 - voh)
end

local function Fd_burley(nol, nov, loh, rough)
	local f90 = 0.5 + 2 * rough * loh * loh
	return (1 + (f90 - 1) * pow5(1 - nol)) * (1 + (f90 - 1) * pow5(1 - nov)) / PI
end

-- radical inverse for a low discrepancy sequence
local function vdc(i)
	local bits = i
	bits = bit.bor(bit.lshift(bits, 16), bit.rshift(bits, 16))
	bits = bit.bor(bit.lshift(bit.band(bits, 0x55555555), 1), bit.rshift(bit.band(bits, 0xAAAAAAAA), 1))
	bits = bit.bor(bit.lshift(bit.band(bits, 0x33333333), 2), bit.rshift(bit.band(bits, 0xCCCCCCCC), 2))
	bits = bit.bor(bit.lshift(bit.band(bits, 0x0F0F0F0F), 4), bit.rshift(bit.band(bits, 0xF0F0F0F0), 4))
	bits = bit.bor(bit.lshift(bit.band(bits, 0x00FF00FF), 8), bit.rshift(bit.band(bits, 0xFF00FF00), 8))
	return (bits % 4294967296) * 2.3283064365386963e-10
end

local N = 60000

-- directional albedo of D V F NoL for a view with n.v = nov, sampling the half vector from D (cos weighted by n.h)
local function specular_albedo(alpha, nov, f0)
	local vx, vz = sqrt(1 - nov * nov), nov
	local sum = 0

	for i = 0, N - 1 do
		local xi1, xi2 = (i + 0.5) / N, vdc(i)
		local cos_t = sqrt((1 - xi2) / (1 + (alpha * alpha - 1) * xi2))
		local sin_t = sqrt(1 - cos_t * cos_t)
		local phi = 2 * PI * xi1
		local hx, hy, hz = cos(phi) * sin_t, sin(phi) * sin_t, cos_t
		local voh = vx * hx + vz * hz

		if voh > 0 then
			-- L = reflect(-V, H)
			local lz = 2 * voh * hz - vz
			local nol = lz

			if nol > 0 then
				-- pdf of L: D noh / (4 voh), the integrand D V F nol
				local v = V_smith(alpha, nov, nol)
				local f = F_schlick(f0, voh)
				sum = sum + v * f * nol * 4 * voh / hz
			end
		end
	end

	return sum / N
end

-- directional albedo of the burley diffuse times (1 - F), white albedo, cosine weighted samples of L
local function diffuse_albedo(rough, nov, f0, with_fresnel)
	local vx, vz = sqrt(1 - nov * nov), nov
	local sum = 0

	for i = 0, N - 1 do
		local xi1, xi2 = (i + 0.5) / N, vdc(i)
		local r = sqrt(xi2)
		local phi = 2 * PI * xi1
		local lx, ly, lz = r * cos(phi), r * sin(phi), sqrt(1 - xi2)
		local hx, hy, hz = vx + lx, ly, vz + lz
		local hl = sqrt(hx * hx + hy * hy + hz * hz)
		local loh = (lx * hx + ly * hy + lz * hz) / hl
		local fd = Fd_burley(lz, nov, loh, rough)
		local kd = with_fresnel and (1 - F_schlick(f0, loh)) or 1
		sum = sum + kd * fd * PI
	end

	return sum / N
end

local function lambert_with_fresnel(nov, f0)
	local vx, vz = sqrt(1 - nov * nov), nov
	local sum = 0

	for i = 0, N - 1 do
		local xi1, xi2 = (i + 0.5) / N, vdc(i)
		local r = sqrt(xi2)
		local phi = 2 * PI * xi1
		local lx, ly, lz = r * cos(phi), r * sin(phi), sqrt(1 - xi2)
		local hx, hy, hz = vx + lx, ly, vz + lz
		local hl = sqrt(hx * hx + hy * hy + hz * hz)
		local loh = (lx * hx + ly * hy + lz * hz) / hl
		sum = sum + 1 - F_schlick(f0, loh)
	end

	return sum / N
end

-- the model now in surface_lighting.lua: the specular with the Kulla Conty compensation, the diffuse
-- (1 - E(n.v)) (1 - F(n.l)) / (1 - average F), white albedo, cosine weighted samples of L
-- EON (Portsmouth, Kutz, Hill 2024), the diffuse in surface_lighting.lua since 2026-10-15 (the formulas in ibl.lua Fd_EON)
local function eon(albedo, rough, nol, nov, lov)
	local A = 1 / (1 + (0.5 - 2 / (3 * PI)) * rough)
	local B = rough * A
	local s_term = lov - nol * nov
	local t = s_term > 0 and max(nol, nov) or 1
	local mean = A * (1 + (2 / 3 - 28 / (15 * PI)) * rough)

	local function E(mu)
		local x = 1 - mu
		return A + B * x * (0.0571085289 + x * (0.491881867 + x * (-0.332181442 + x * 0.0714429953)))
	end

	return (albedo * (A + B * s_term / t) + albedo * albedo * (mean / (1 - albedo * (1 - mean))) * ((1 - E(nol)) * (1 - E(nov)) / max(1 - mean, 1e-4))) / PI
end

local function eon_albedo(albedo, rough, nov)
	local vx, vz = sqrt(1 - nov * nov), nov
	local sum = 0

	for i = 0, N - 1 do
		local xi1, xi2 = (i + 0.5) / N, vdc(i)
		local r = sqrt(xi2)
		local phi = 2 * PI * xi1
		local lx, ly, lz = r * cos(phi), r * sin(phi), sqrt(1 - xi2)
		sum = sum + eon(albedo, rough, lz, nov, lx * vx + lz * vz) * PI
	end

	return sum / N
end

local function coupled_total(rough, nov, f0)
	local alpha = rough * rough
	local energy = 1 + f0 * (1 / specular_albedo(alpha, nov, 1) - 1)
	local spec = specular_albedo(alpha, nov, f0) * energy
	local average = f0 + (1 - f0) / 21
	local vx, vz = sqrt(1 - nov * nov), nov
	local sum = 0

	for i = 0, N - 1 do
		local xi1, xi2 = (i + 0.5) / N, vdc(i)
		local r = sqrt(xi2)
		local phi = 2 * PI * xi1
		local lx, lz = r * cos(phi), sqrt(1 - xi2)
		sum = sum + eon(1, rough, lz, nov, lx * vx + lz * vz) * PI * (1 - F_schlick(f0, lz)) / (1 - average)
	end

	return spec, max(1 - spec, 0) * sum / N
end

print("directional albedo, 1 is all of the light and a physical surface cannot send back more")
print("perceptual roughness  n.v   white metal (F0 1) before / compensated   dielectric F0 0.04: before (specular + (1 - F) burley)   now (compensated specular + fresnel coupled EON diffuse)")

for _, rough in ipairs{0.1, 0.3, 0.5, 0.7, 1.0} do
	for _, nov in ipairs{0.1, 0.5, 1.0} do
		local alpha = rough * rough
		local metal = specular_albedo(alpha, nov, 1)
		local spec = specular_albedo(alpha, nov, 0.04)
		local diff = diffuse_albedo(rough, nov, 0.04, true)
		local now_spec, now_diffuse = coupled_total(rough, nov, 0.04)
		print(string.format("      %.1f             %.1f   %.3f / %.3f             %.3f + %.3f = %.3f                    %.3f + %.3f = %.3f", rough, nov, metal, specular_albedo(rough * rough, nov, 1) * (1 + 1 * (1 / specular_albedo(rough * rough, nov, 1) - 1)), spec, diff, spec + diff, now_spec, now_diffuse, now_spec + now_diffuse))
	end
end

print("\nEON diffuse alone, directional albedo (cosine weighted), a white surface must send back 1 at every roughness and view")

for _, rough in ipairs{0, 0.3, 0.6, 1.0} do
	local row = {}

	for _, nov in ipairs{0.1, 0.3, 0.6, 1.0} do
		row[#row + 1] = string.format("nv %.1f: %.3f", nov, eon_albedo(1, rough, nov))
	end

	print(string.format("roughness %.1f   %s   (albedo 0.5 at n.v 0.6: %.3f)", rough, table.concat(row, "   "), eon_albedo(0.5, rough, 0.6)))
end

print("\nburley diffuse alone (the model before 2026-10-15), white, no fresnel: 1 is Lambert")

for _, rough in ipairs{0, 0.5, 1.0} do
	local row = {}

	for _, nov in ipairs{0.1, 0.3, 0.6, 1.0} do
		row[#row + 1] = string.format("nv %.1f: %.3f", nov, diffuse_albedo(rough, nov, 0, false))
	end

	print(string.format("roughness %.1f   %s", rough, table.concat(row, "   ")))
end

-- exact unpolarised Fresnel of a dielectric against Schlick with F0 = ((n - 1) / (n + 1))^2
print("\nschlick against the exact fresnel of a dielectric, n = 1.5 (F0 0.04)")

local function fresnel_dielectric(cos_i, n)
	local sin_t2 = (1 - cos_i * cos_i) / (n * n)
	local cos_t = sqrt(1 - sin_t2)
	local rs = ((cos_i - n * cos_t) / (cos_i + n * cos_t)) ^ 2
	local rp = ((n * cos_i - cos_t) / (n * cos_i + cos_t)) ^ 2
	return (rs + rp) / 2
end

for _, angle in ipairs{0, 30, 60, 75, 85, 89} do
	local c = cos(math.rad(angle))
	print(string.format("  %2d degrees: exact %.4f schlick %.4f", angle, fresnel_dielectric(c, 1.5), F_schlick(0.04, c)))
end

os.exit(0)
