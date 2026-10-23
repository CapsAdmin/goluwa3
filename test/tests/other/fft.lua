local T = import("test/environment.lua")
local fft = import("goluwa/math/fft.lua")
local ffi = require("ffi")

T.Test("fft 2d round trip returns the input", function()
	local n = 16
	local re, im = ffi.new("double[?]", n * n), ffi.new("double[?]", n * n)
	local original = {}

	for i = 0, n * n - 1 do
		original[i] = math.sin(i * 0.37) + (i % 5)
		re[i] = original[i]
	end

	fft.Transform2D(re, im, n, false)
	fft.Transform2D(re, im, n, true)

	for i = 0, n * n - 1 do
		T(re[i] / (n * n))["~"](original[i], 1e-9)
		T(im[i] / (n * n))["~"](0, 1e-9)
	end
end)

T.Test("fft 2d of a single mode lands in one bin", function()
	local n = 32
	local re, im = ffi.new("double[?]", n * n), ffi.new("double[?]", n * n)

	for y = 0, n - 1 do
		for x = 0, n - 1 do
			re[y * n + x] = math.cos(2 * math.pi * (3 * x + 5 * y) / n)
		end
	end

	fft.Transform2D(re, im, n, false)
	T(re[5 * n + 3])["~"](n * n / 2, 1e-6)
	T(re[(n - 5) * n + (n - 3)])["~"](n * n / 2, 1e-6)
	T(re[0])["~"](0, 1e-6)
end)
