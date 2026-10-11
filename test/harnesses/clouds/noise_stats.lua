local ffi = require("ffi")
local u32 = function(x)
	return tonumber(ffi.cast("uint32_t", x))
end

local function mul(a, b)
	return u32(ffi.cast("uint64_t", a) * b)
end

local function pcg(x, y, z)
	x = u32(mul(x, 1664525) + 1013904223)
	y = u32(mul(y, 1664525) + 1013904223)
	z = u32(mul(z, 1664525) + 1013904223)
	x = u32(x + mul(y, z))
	y = u32(y + mul(z, x))
	z = u32(z + mul(x, y))
	x = bit.bxor(x, bit.rshift(x, 16)) % 2 ^ 32
	y = bit.bxor(y, bit.rshift(y, 16)) % 2 ^ 32
	z = bit.bxor(z, bit.rshift(z, 16)) % 2 ^ 32
	x = u32(x + mul(y, z))
	y = u32(y + mul(z, x))
	z = u32(z + mul(x, y))
	return x, y, z
end

local function rnd(cx, cy, cz, p, seed)
	local x, y, z = pcg(
		(cx + p * 64) % p + seed,
		(cy + p * 64) % p + seed * 7,
		(cz + p * 64) % p + seed * 13
	)
	return bit.band(x, 0xffff) / 65535,
	bit.band(y, 0xffff) / 65535,
	bit.band(z, 0xffff) / 65535
end

local floor = math.floor

local function grad(cx, cy, cz, fx, fy, fz, ox, oy, oz, p, seed)
	local gx, gy, gz = rnd(cx + ox, cy + oy, cz + oz, p, seed)
	return (gx * 2 - 1) * (fx - ox) + (gy * 2 - 1) * (fy - oy) + (gz * 2 - 1) * (fz - oz)
end

local function mix(a, b, t)
	return a + (b - a) * t
end

local function perlin(x, y, z, p, seed)
	local cx, cy, cz = floor(x), floor(y), floor(z)
	local fx, fy, fz = x - cx, y - cy, z - cz

	local function s(f)
		return f * f * f * (f * (f * 6 - 15) + 10)
	end

	local ux, uy, uz = s(fx), s(fy), s(fz)

	local function g(a, b, c)
		return grad(cx, cy, cz, fx, fy, fz, a, b, c, p, seed)
	end

	return mix(
		mix(mix(g(0, 0, 0), g(1, 0, 0), ux), mix(g(0, 1, 0), g(1, 1, 0), ux), uy),
		mix(mix(g(0, 0, 1), g(1, 0, 1), ux), mix(g(0, 1, 1), g(1, 1, 1), ux), uy),
		uz
	)
end

local function worley(x, y, z, p, seed)
	local cx, cy, cz = floor(x), floor(y), floor(z)
	local d = 1e9

	for oz = -1, 1 do
		for oy = -1, 1 do
			for ox = -1, 1 do
				local rx, ry, rz = rnd(cx + ox, cy + oy, cz + oz, p, seed)
				rx, ry, rz = ox + rx - (x - cx), oy + ry - (y - cy), oz + rz - (z - cz)
				d = math.min(d, rx * rx + ry * ry + rz * rz)
			end
		end
	end

	return 1 - math.min(math.sqrt(d), 1)
end

local function pfbm(x, y, z, f, oct, seed)
	local sum, amp, tot = 0, 1, 0

	for i = 0, oct - 1 do
		sum = sum + perlin(x * f, y * f, z * f, f, seed + i) * amp
		tot = tot + amp
		amp = amp * 0.5
		f = f * 2
	end

	return sum / tot
end

local function wfbm(x, y, z, f, seed)
	return worley(x * f, y * f, z * f, f, seed) * 0.625 + worley(x * f * 2, y * f * 2, z * f * 2, f * 2, seed + 1) * 0.25 + worley(x * f * 4, y * f * 4, z * f * 4, f * 4, seed + 2) * 0.125
end

local function sat(x)
	return math.max(0, math.min(1, x))
end

local function remap(v, l0, h0, l1, h1)
	return l1 + (v - l0) * (h1 - l1) / (h0 - l0)
end

local N = 20
local vals = {r = {}, fbm = {}, base = {}}

for iz = 0, N - 1 do
	for iy = 0, N - 1 do
		for ix = 0, N - 1 do
			local x, y, z = (ix + 0.37) / N, (iy + 0.61) / N, (iz + 0.13) / N
			local per = sat(0.5 + 0.8 * pfbm(x, y, z, 4, 6, 0))
			local wor = wfbm(x, y, z, 4, 10)
			local pw = sat(remap(per, wor - 1, 1, 0, 1))
			local g, b, a = wfbm(x, y, z, 8, 20), wfbm(x, y, z, 16, 30), wfbm(x, y, z, 32, 40)
			local fbm = g * 0.625 + b * 0.25 + a * 0.125
			table.insert(vals.r, pw)
			table.insert(vals.fbm, fbm)
			table.insert(vals.base, remap(pw, fbm - 1, 1, 0, 1))
		end
	end
end

for k, t in pairs(vals) do
	table.sort(t)
	local q = {}

	for _, p in ipairs{0.02, 0.1, 0.25, 0.5, 0.75, 0.9, 0.98} do
		q[#q + 1] = string.format("%.2f:%.3f", p, t[math.max(1, floor(p * #t))])
	end

	print(k, table.concat(q, "  "))
end
