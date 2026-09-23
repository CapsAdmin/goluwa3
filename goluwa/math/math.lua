math.tau = math.pi * 2

function math.linear2gamma(n, gamma)
	gamma = gamma or 2.4

	if n <= 0.04045 then return n / 12.92 end

	return ((n + 0.055) / 1.055) ^ gamma
end

function math.gamma2linear(n, gamma)
	gamma = gamma or 2.4

	if n < 0.0031308 then
		return n * 12.92
	else
		return 1.055 * (n ^ (1.0 / gamma)) - 0.055
	end
end

function math.normalizeangle(a)
	return (a + math.pi) % math.tau - math.pi
end

function math.map(num, in_min, in_max, out_min, out_max)
	return (num - in_min) * (out_max - out_min) / (in_max - in_min) + out_min
end

function math.normalize(num, min, max)
	return (num - min) / (max - min)
end

function math.pow2ceil(n)
	return 2 ^ math.ceil(math.log(n) / math.log(2))
end

function math.pow2floor(n)
	return 2 ^ math.floor(math.log(n) / math.log(2))
end

function math.pow2round(n)
	return 2 ^ math.round(math.log(n) / math.log(2))
end

function math.round(num, idp)
	if idp and idp > 0 then
		local mult = 10 ^ idp
		return math.floor(num * mult + 0.5) / mult
	end

	return math.floor(num + 0.5)
end

function math.randomf(min, max)
	min = min or -1
	max = max or 1
	return min + (math.random() * (max - min))
end

function math.clamp(self, min, max)
	return math.min(math.max(self, min), max)
end

function math.sign(value)
	return value < 0 and -1 or 1
end

function math.lerp(m, a, b)
	return (b - a) * m + a
end

function math.len(x)
	local len = 1

	while x > 9999 do
		x = x / 10000
		len = len + 4
	end

	while x > 99 do
		x = x / 100
		len = len + 2
	end

	if x > 9 then len = len + 1 end

	return len
end

function math.digit10(x, n)
	while n > 0 do
		x = x / 10
		n = n - 1
	end

	return math.floor(x % 10)
end

function math.approach(cur, target, inc)
	inc = math.abs(inc)

	if cur < target then
		return math.clamp(cur + inc, cur, target)
	elseif cur > target then
		return math.clamp(cur - inc, target, cur)
	end

	return target
end

local inf, ninf = math.huge, -math.huge

function math.isvalid(num)
	return num and num ~= inf and num ~= ninf and (num >= 0 or num <= 0)
end

function math.tostring(num)
	local t = {}
	local len = math.len(num)

	for i = 0, len - 1 do
		t[len - i] = math.digit10(num, i)
	end

	return list.concat(t)
end

do
	local ffi = require("ffi")
	local bits = ffi.new("union { uint32_t u; float f; }")

	function math.half2float(h)
		local s = bit.band(bit.rshift(h, 15), 1)
		local e = bit.band(bit.rshift(h, 10), 0x1f)
		local m = bit.band(h, 0x3ff)

		if e == 0 then
			if m == 0 then return s == 1 and -0.0 or 0.0 end

			while bit.band(m, 0x400) == 0 do
				m = bit.lshift(m, 1)
				e = e - 1
			end

			e = e + 1
			m = bit.band(m, bit.bnot(0x400))
		elseif e == 31 then
			if m == 0 then return s == 1 and -math.huge or math.huge end

			return 0 / 0
		end

		bits.u = bit.bor(bit.lshift(s, 31), bit.lshift(e + 127 - 15, 23), bit.lshift(m, 13))
		return bits.f
	end
end
