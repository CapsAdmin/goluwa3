local T = import("test/environment.lua")
local ffi = require("ffi")
local fft = import("goluwa/math/fft.lua")
local Texture = import("goluwa/render/texture.lua")
local height_from_normals = import("goluwa/render/height_from_normals.lua")
local N = 64

local function normals_texture(slope_x, slope_y)
	local pixels = ffi.new("uint8_t[?]", N * N * 4)

	for i = 0, N * N - 1 do
		local length = math.sqrt(slope_x[i] ^ 2 + slope_y[i] ^ 2 + 1)
		pixels[i * 4] = math.floor((-slope_x[i] / length * 0.5 + 0.5) * 255 + 0.5)
		pixels[i * 4 + 1] = math.floor((-slope_y[i] / length * 0.5 + 0.5) * 255 + 0.5)
		pixels[i * 4 + 2] = 255
		pixels[i * 4 + 3] = 255
	end

	return Texture.New{buffer = pixels, width = N, height = N, format = "r8g8b8a8_unorm"},
	pixels
end

local function cpu_solve(pixels, cutoff)
	local re, im, re2, im2 = ffi.new("double[?]", N * N),
	ffi.new("double[?]", N * N),
	ffi.new("double[?]", N * N),
	ffi.new("double[?]", N * N)

	for i = 0, N * N - 1 do
		local nx, ny = pixels[i * 4] / 255 * 2 - 1, pixels[i * 4 + 1] / 255 * 2 - 1
		local nz = math.sqrt(math.max(1 - nx * nx - ny * ny, 0.0025))
		re[i], re2[i] = -nx / nz, -ny / nz
	end

	fft.Transform2D(re, im, N, false)
	fft.Transform2D(re2, im2, N, false)
	local hr, hi = ffi.new("double[?]", N * N), ffi.new("double[?]", N * N)

	for v = 0, N - 1 do
		local fv = (v <= N / 2 and v or v - N) * 2 * math.pi / N

		for u = 0, N - 1 do
			local fu = (u <= N / 2 and u or u - N) * 2 * math.pi / N
			local den = fu * fu + fv * fv
			local i = v * N + u

			if den > 1e-12 then
				local cycles = math.sqrt(den) * N / (2 * math.pi)
				local weight = 1

				if cutoff > 0 then
					local t = math.min(math.max((cycles - cutoff * 0.5) / (cutoff * 0.5), 0), 1)
					weight = t * t * (3 - 2 * t)
				end

				hr[i] = (fu * im[i] + fv * im2[i]) / den * weight
				hi[i] = (-fu * re[i] - fv * re2[i]) / den * weight
			end
		end
	end

	fft.Transform2D(hr, hi, N, true)
	local out = {}

	for i = 0, N * N - 1 do
		out[i] = hr[i] / (N * N)
	end

	return out
end

T.Test3D("height_from_normals matches the cpu fft solve", function()
	local seed = 7
	local slope_x, slope_y = {}, {}

	for i = 0, N * N - 1 do
		seed = (seed * 1103515245 + 12345) % 2147483648
		slope_x[i] = (seed / 2147483648 - 0.5) * 0.6
		seed = (seed * 1103515245 + 12345) % 2147483648
		slope_y[i] = (seed / 2147483648 - 0.5) * 0.6
	end

	local texture, pixels = normals_texture(slope_x, slope_y)
	local expected = cpu_solve(pixels, 2)
	local buffer = height_from_normals.Solve(texture, 2)
	local got = ffi.cast("float*", buffer:Map())
	local worst, scale = 0, 0

	for i = 0, N * N - 1 do
		worst = math.max(worst, math.abs(got[i] - expected[i]))
		scale = math.max(scale, math.abs(expected[i]))
	end

	T(worst / scale < 0.002)["=="](true)
	buffer:Remove()
end)

T.Test3D("height_from_normals recovers a known surface from its slopes", function()
	local height, slope_x, slope_y = {}, {}, {}
	local amplitude = 3

	for y = 0, N - 1 do
		for x = 0, N - 1 do
			local i = y * N + x
			local a, b = 2 * math.pi * 3 * x / N, 2 * math.pi * 2 * y / N
			height[i] = amplitude * (math.sin(a) + 0.5 * math.cos(b + a))
			slope_x[i] = amplitude * (
					math.cos(a) * 2 * math.pi * 3 / N - 0.5 * math.sin(b + a) * 2 * math.pi * 3 / N
				)
			slope_y[i] = amplitude * (-0.5 * math.sin(b + a) * 2 * math.pi * 2 / N)
		end
	end

	local texture = normals_texture(slope_x, slope_y)
	local buffer = height_from_normals.Solve(texture, 0)
	local got = ffi.cast("float*", buffer:Map())
	local mean_got, mean_expected = 0, 0

	for i = 0, N * N - 1 do
		mean_got, mean_expected = mean_got + got[i], mean_expected + height[i]
	end

	mean_got, mean_expected = mean_got / (N * N), mean_expected / (N * N)
	local worst = 0

	for i = 0, N * N - 1 do
		worst = math.max(worst, math.abs((got[i] - mean_got) - (height[i] - mean_expected)))
	end

	T(worst < amplitude * 0.08)["=="](true)
	buffer:Remove()
end)

T.Test3D("height_from_normals.Solve fades out frequencies finer than the height cut", function()
	local slope_x, slope_y = {}, {}

	for y = 0, N - 1 do
		for x = 0, N - 1 do
			local i = y * N + x
			slope_x[i] = 0.4 * math.cos(2 * math.pi * 20 * x / N)
			slope_y[i] = 0
		end
	end

	local texture = normals_texture(slope_x, slope_y)

	local function amplitude(height_cut)
		local buffer = height_from_normals.Solve(texture, 0, height_cut)
		local got = ffi.cast("float*", buffer:Map())
		local lo, hi = math.huge, -math.huge

		for i = 0, N * N - 1 do
			lo, hi = math.min(lo, got[i]), math.max(hi, got[i])
		end

		buffer:Remove()
		return hi - lo
	end

	T(amplitude(4) < amplitude(0) * 0.05)["=="](true)
	T(amplitude(32) > amplitude(0) * 0.9)["=="](true)
end)
