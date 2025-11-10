local audio = require("audio")
local threads = require("threads")
local time = 0

local function getpitch(offset)
	return 440 * 2 ^ ((offset - 48) / 12)
end

local function saw(offset)
	return (time * getpitch(offset)) % 1
end

local function pwm(offset, w)
	w = w or 0.5
	return (time * getpitch(offset)) % 1 > w and 1 or 0
end

local function sin(offset)
	return math.sin(time * math.pi * 2 * getpitch(offset))
end

local v

local function tri(offset)
	v = (time * getpitch(offset)) % 1
	return v > 0.5 and (-v + 1) or v
end

local function super(func, offset, detune, amount)
	local v = 0

	for i = -amount, amount do
		v = v + func(offset + (i / detune))
	end

	return v
end

local function waveform()
	local t = (time * 8)
	local w = 0 --pwm(30, math.tan(t))
    
	if t % 1 > 0.9 and t % 1 < 0.95 then
		w = w + (math.random() * math.sin(t))
	end

	if t % 8 < 0.5 then w = w + math.random() end

	if (t % 4 > 2 and t % 4 < 2.6) then w = w + pwm(12) end

	if (t % 4 > 2.6 and t % 4 < 3) then w = w + pwm(0) end

	return w
end

local length_ms = 7000

function audio.callback(buffer, num_samples, config)
	for i = 0, num_samples - 1, 2 do
		for j = 0, config.channels - 1 do
			local w = waveform()
			buffer[i + j] = w
			buffer[i + j] = w
		end

		time = time + (1 / config.sample_rate)
	end
end

audio.start()
threads.sleep(length_ms)
audio.stop()
