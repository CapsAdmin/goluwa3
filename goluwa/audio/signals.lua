local ffi = require("ffi")
local signals = {}

local function next_noise(seed)
	seed = (seed * 1103515245 + 12345) % 2147483648
	return seed, seed / 1073741824 - 1
end

local function normalize_peak(data, frames)
	local peak = 0

	for i = 0, frames - 1 do
		peak = math.max(peak, math.abs(data[i]))
	end

	for i = 0, frames - 1 do
		data[i] = data[i] / peak
	end
end

function signals.Clap(sample_rate)
	local frames = math.floor(sample_rate * 0.08)
	local data = ffi.new("float[?]", frames)
	local w0 = 2 * math.pi * 1500 / sample_rate
	local alpha = math.sin(w0) / (2 * 2)
	local a0 = 1 + alpha
	local b0, b2 = alpha / a0, -alpha / a0
	local a1, a2 = -2 * math.cos(w0) / a0, (1 - alpha) / a0
	local x1, x2, y1, y2 = 0, 0, 0, 0
	local seed, noise = 7

	for i = 0, frames - 1 do
		seed, noise = next_noise(seed)
		local x = noise * math.exp(-i / (sample_rate * 0.002))
		local y = b0 * x + b2 * x2 - a1 * y1 - a2 * y2
		x2, x1, y2, y1 = x1, x, y1, y
		data[i] = 2 * y + x * math.exp(-i / (sample_rate * 0.001))
	end

	normalize_peak(data, frames)
	return data, frames
end

function signals.Boom(sample_rate)
	local frames = math.floor(sample_rate * 1.5)
	local data = ffi.new("float[?]", frames)
	local lowpass = 1 - math.exp(-2 * math.pi * 300 / sample_rate)
	local phase, rumble = 0, 0
	local seed, noise = 11

	for i = 0, frames - 1 do
		local t = i / sample_rate
		phase = phase + 2 * math.pi * (40 + 50 * math.exp(-t / 0.08)) / sample_rate
		seed, noise = next_noise(seed)
		rumble = rumble + (noise - rumble) * lowpass
		data[i] = (
				1 - math.exp(-t / 0.004)
			) * math.exp(-t / 0.25) * math.sin(phase) + 2 * rumble * math.exp(-t / 0.04)
	end

	normalize_peak(data, frames)
	return data, frames
end

return signals
