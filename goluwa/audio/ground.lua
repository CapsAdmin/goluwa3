local ffi = require("ffi")
local bit = require("bit")
local ground = {}
ground.IR_SIZE = 1280
ground.READ_AHEAD = 512
ground.FFT_SIZE = 2048
ground.RIGID = 5000000
ground.AIR_DENSITY = 1.204
ground.SPEED_OF_SOUND = 343.3
local TAPER = 128
local SQRT_PI = math.sqrt(math.pi)
local SIZE = ground.FFT_SIZE
local HALF = SIZE / 2
local float_array_t = ffi.typeof("float[?]")
local double_array_t = ffi.typeof("double[?]")

do
	local bits = 0

	while 2 ^ bits < SIZE do
		bits = bits + 1
	end

	ground.cos_table = double_array_t(HALF)
	ground.sin_table = double_array_t(HALF)
	ground.reversed = ffi.new("int32_t[?]", SIZE)

	for i = 0, HALF - 1 do
		ground.cos_table[i] = math.cos(2 * math.pi * i / SIZE)
		ground.sin_table[i] = math.sin(2 * math.pi * i / SIZE)
	end

	for i = 0, SIZE - 1 do
		local r = 0

		for b = 0, bits - 1 do
			if bit.band(bit.rshift(i, b), 1) == 1 then
				r = bit.bor(r, bit.lshift(1, bits - 1 - b))
			end
		end

		ground.reversed[i] = r
	end
end

local cos_table, sin_table, reversed = ground.cos_table, ground.sin_table, ground.reversed

-- in place complex transform of SIZE points; the inverse is unscaled
function ground.FFT(re, im, inverse)
	for i = 0, SIZE - 1 do
		local j = reversed[i]

		if j > i then
			re[i], re[j] = re[j], re[i]
			im[i], im[j] = im[j], im[i]
		end
	end

	local sign = inverse and 1 or -1
	local size = 2

	while size <= SIZE do
		local half = size / 2
		local step = SIZE / size

		for start = 0, SIZE - 1, size do
			for k = 0, half - 1 do
				local wr, wi = cos_table[k * step], sign * sin_table[k * step]
				local a, b = start + k, start + k + half
				local tr = re[b] * wr - im[b] * wi
				local ti = re[b] * wi + im[b] * wr
				re[b] = re[a] - tr
				im[b] = im[a] - ti
				re[a] = re[a] + tr
				im[a] = im[a] + ti
			end
		end

		size = size * 2
	end
end

-- Weideman's rational approximation of the Faddeeva function w(z) = exp(-z^2) erfc(-i z) for Im z >= 0
local WEIDEMAN_N = 32
local WEIDEMAN_L = math.sqrt(WEIDEMAN_N / math.sqrt(2))
local weideman = {}

do
	local n = WEIDEMAN_N
	local m, m2 = 2 * n, 4 * n
	local f = {}

	for j = 0, m2 - 1 do
		f[j] = 0
	end

	for idx = 1, m2 - 1 do
		local t = WEIDEMAN_L * math.tan((idx - m) * math.pi / m / 2)
		f[idx] = math.exp(-t * t) * (WEIDEMAN_L * WEIDEMAN_L + t * t)
	end

	local a = {}

	for k = 1, n do
		local sum = 0

		for j = 0, m2 - 1 do
			sum = sum + f[(j + m) % m2] * math.cos(2 * math.pi * k * j / m2)
		end

		a[k] = sum / m2
	end

	for i = 1, n do
		weideman[i] = a[n - i + 1]
	end
end

local function faddeeva(x, y)
	local l = WEIDEMAN_L
	local nr, ni = l - y, x
	local dr, di = l + y, -x
	local dd = dr * dr + di * di
	local zr, zi = (nr * dr + ni * di) / dd, (ni * dr - nr * di) / dd
	local pr, pi = 0, 0

	for i = 1, WEIDEMAN_N do
		pr, pi = pr * zr - pi * zi + weideman[i], pr * zi + pi * zr
	end

	local d2r, d2i = dr * dr - di * di, 2 * dr * di
	local d2 = d2r * d2r + d2i * d2i
	local ar, ai = 2 * (pr * d2r + pi * d2i) / d2, 2 * (pi * d2r - pr * d2i) / d2
	return ar + dr / dd / SQRT_PI, ai - di / dd / SQRT_PI
end

ground.Faddeeva = faddeeva

-- flow resistivity (Pa s / m2) from the mid band absorption of a ground material: snow about 30 kPa, grass 150 kPa, dirt 250 kPa, sand 350 kPa, anything hard effectively rigid
function ground.Resistivity(absorption)
	local a = math.clamp(absorption, 0.001, 0.99)
	return 250000 * ((1 - a) / a) ^ 1.2
end

-- complex reflection coefficient of a spherical wave on an impedance plane (Delany Bazley, Weyl van der Pol), time dependence exp(-i w t): the reflected wave is Q exp(i k r2) / r2 against exp(i k r1) / r1 for the direct one
function ground.Coefficient(frequency, sigma, r2, sin_psi)
	local x = ground.AIR_DENSITY * frequency / sigma
	local zr = 1 + 0.0571 * x ^ -0.754
	local zi = 0.087 * x ^ -0.732
	local zz = zr * zr + zi * zi
	local br, bi = zr / zz, -zi / zz
	local ar, ai = zr * sin_psi - 1, zi * sin_psi
	local cr, ci = zr * sin_psi + 1, zi * sin_psi
	local cc = cr * cr + ci * ci
	local rr, ri = (ar * cr + ai * ci) / cc, (ai * cr - ar * ci) / cc
	local k = 2 * math.pi * frequency / ground.SPEED_OF_SOUND
	local root = math.sqrt(k * r2 / 2) * 0.7071067811865476
	local pr, pi = sin_psi + br, bi
	local wr, wi = root * pr - root * pi, root * pi + root * pr

	if wi < 0 then wr, wi = -wr, -wi end

	local fr, fi = faddeeva(wr, wi)
	local tr, ti = wr * fr - wi * fi, wr * fi + wi * fr
	local f_r, f_i = 1 - SQRT_PI * ti, SQRT_PI * tr
	local omr, omi = 1 - rr, -ri
	return rr + omr * f_r - omi * f_i, ri + omr * f_i + omi * f_r
end

do
	local nodes = {}

	for k = 0, 64 do
		nodes[#nodes + 1] = k
	end

	for k = 68, 256, 4 do
		nodes[#nodes + 1] = k
	end

	for k = 272, HALF, 16 do
		nodes[#nodes + 1] = k
	end

	local re, im = double_array_t(SIZE), double_array_t(SIZE)
	local node_re, node_im = double_array_t(#nodes), double_array_t(#nodes)

	-- ir[j] is the filter of the conjugated coefficient (the mixer convolves with exp(-i w n)) from n = -ahead, so the reflection arrives ahead samples into it: read it ahead samples earlier
	function ground.DesignFilter(
		ir,
		sigma,
		r2,
		sin_psi,
		sample_rate,
		ahead,
		scatter_low,
		scatter_mid,
		scatter_high
	)
		for i, k in ipairs(nodes) do
			local frequency = math.max(k * sample_rate / SIZE, 1)
			local q_r, q_i = ground.Coefficient(frequency, sigma, r2, sin_psi)
			local position = math.clamp(math.log(frequency / 250) / math.log(1500 / 250), 0, 2)
			local scatter = position < 1 and
				scatter_low + (
					scatter_mid - scatter_low
				) * position or
				scatter_mid + (
					scatter_high - scatter_mid
				) * math.min(math.log(frequency / 1500) / math.log(8000 / 1500), 1)
			local keep = math.sqrt(math.max(1 - scatter, 0))
			node_re[i - 1], node_im[i - 1] = q_r * keep, -q_i * keep
		end

		local at = 0

		for k = 0, HALF do
			while nodes[at + 2] and nodes[at + 2] <= k do
				at = at + 1
			end

			local lo, hi = nodes[at + 1], nodes[at + 2]
			local t = hi and (k - lo) / (hi - lo) or 0
			local next_at = hi and at + 1 or at
			re[k] = node_re[at] + (node_re[next_at] - node_re[at]) * t
			im[k] = node_im[at] + (node_im[next_at] - node_im[at]) * t
		end

		im[0], im[HALF] = 0, 0

		for k = 1, HALF - 1 do
			re[SIZE - k], im[SIZE - k] = re[k], -im[k]
		end

		ground.FFT(re, im, true)

		for j = 0, ground.IR_SIZE - 1 do
			local value = re[(j - ahead) % SIZE] / SIZE

			if j >= ground.IR_SIZE - TAPER then
				value = value * 0.5 * (1 + math.cos(math.pi * (j - (ground.IR_SIZE - TAPER)) / TAPER))
			end

			ir[j] = value
		end
	end
end

function ground.CreateIR()
	return float_array_t(ground.IR_SIZE)
end

function ground.CreateConvolver()
	return {
		h_re = double_array_t(SIZE),
		h_im = double_array_t(SIZE),
		re = double_array_t(SIZE),
		im = double_array_t(SIZE),
		serial = -1,
	}
end

function ground.SetFilter(convolver, ir)
	local re, im = convolver.re, convolver.im

	for i = 0, SIZE - 1 do
		re[i], im[i] = i < ground.IR_SIZE and ir[i] or 0, 0
	end

	ground.FFT(re, im, false)

	for i = 0, SIZE - 1 do
		convolver.h_re[i], convolver.h_im[i] = re[i], im[i]
	end
end

-- output[start .. start + frames) = input convolved with the filter, from a ring of power of two size
function ground.Convolve(convolver, input, input_mask, output, output_mask, start, frames)
	local re, im, h_re, h_im = convolver.re, convolver.im, convolver.h_re, convolver.h_im
	local length = ground.IR_SIZE
	local first = start - (length - 1)
	local used = length - 1 + frames

	for i = 0, used - 1 do
		re[i] = input[bit.band(first + i, input_mask)]
		im[i] = 0
	end

	for i = used, SIZE - 1 do
		re[i], im[i] = 0, 0
	end

	ground.FFT(re, im, false)

	for i = 0, SIZE - 1 do
		local a, b = re[i], im[i]
		re[i] = a * h_re[i] - b * h_im[i]
		im[i] = a * h_im[i] + b * h_re[i]
	end

	ground.FFT(re, im, true)

	for i = 0, frames - 1 do
		output[bit.band(start + i, output_mask)] = re[length - 1 + i] / SIZE
	end
end

return ground
