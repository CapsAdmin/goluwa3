local ffi = require("ffi")
local dsp = {}
dsp.LOW_CROSSOVER = 500
dsp.HIGH_CROSSOVER = 4000
dsp.BAND_CENTERS = {250, 1500, 8000}

function dsp.OnePoleCoefficient(frequency, sample_rate)
	return 1 - math.exp(-2 * math.pi * frequency / sample_rate)
end

function dsp.ReadCubic(buffer, mask, position)
	local index = math.floor(position)
	local f = position - index
	local x0 = buffer[bit.band(index - 1, mask)]
	local x1 = buffer[bit.band(index, mask)]
	local x2 = buffer[bit.band(index + 1, mask)]
	local x3 = buffer[bit.band(index + 2, mask)]
	local c1 = 0.5 * (x2 - x0)
	local c2 = x0 - 2.5 * x1 + 2 * x2 - 0.5 * x3
	local c3 = 0.5 * (x3 - x0) + 1.5 * (x1 - x2)
	return ((c3 * f + c2) * f + c1) * f + x1
end

function dsp.ReadLinear(buffer, mask, position)
	local index = math.floor(position)
	local x1 = buffer[bit.band(index, mask)]
	return x1 + (buffer[bit.band(index + 1, mask)] - x1) * (position - index)
end

do
	local rows = {}

	for i, frequency in ipairs(dsp.BAND_CENTERS) do
		local la = 1 / (1 + (frequency / dsp.LOW_CROSSOVER) ^ 2)
		local lb = 1 / (1 + (frequency / dsp.HIGH_CROSSOVER) ^ 2)
		rows[i] = {la, lb - la, 1 - lb}
	end

	local a, b, c = rows[1], rows[2], rows[3]
	local det = a[1] * (
			b[2] * c[3] - b[3] * c[2]
		) - a[2] * (
			b[1] * c[3] - b[3] * c[1]
		) + a[3] * (
			b[1] * c[2] - b[2] * c[1]
		)
	local inverse = {
		{
			(
				b[2] * c[3] - b[3] * c[2]
			) / det,
			(
				a[3] * c[2] - a[2] * c[3]
			) / det,
			(
				a[2] * b[3] - a[3] * b[2]
			) / det,
		},
		{
			(
				b[3] * c[1] - b[1] * c[3]
			) / det,
			(
				a[1] * c[3] - a[3] * c[1]
			) / det,
			(
				a[3] * b[1] - a[1] * b[3]
			) / det,
		},
		{
			(
				b[1] * c[2] - b[2] * c[1]
			) / det,
			(
				a[2] * c[1] - a[1] * c[2]
			) / det,
			(
				a[1] * b[2] - a[2] * b[1]
			) / det,
		},
	}

	function dsp.WarpBandGains(low, mid, high)
		local i1, i2, i3 = inverse[1], inverse[2], inverse[3]
		return math.max(i1[1] * low + i1[2] * mid + i1[3] * high, 0),
		math.max(i2[1] * low + i2[2] * mid + i2[3] * high, 0),
		math.max(i3[1] * low + i3[2] * mid + i3[3] * high, 0)
	end
end

function dsp.BandGainBound(low, mid, high)
	return math.abs(high) + math.abs(mid - high) + math.abs(low - mid)
end

do
	local LINES = 16
	local LINE_SIZE = 4096
	local LINE_MASK = LINE_SIZE - 1
	local PREDELAY_SIZE = 16384
	local PREDELAY_MASK = PREDELAY_SIZE - 1
	local DELAYS = {
		557,
		607,
		661,
		719,
		787,
		853,
		929,
		1009,
		1103,
		1201,
		1307,
		1423,
		1549,
		1693,
		1847,
		1999,
	}
	local DIFFUSERS = {142, 107, 379, 277}
	local DIFFUSER_GAIN = 0.62
	local DIFFUSER_SIZE = 512
	local DIFFUSER_MASK = DIFFUSER_SIZE - 1
	local reverb_t = ffi.typeof(
		[[
		struct {
			float lines[$][$];
			float predelay_line[$];
			float diffusers[4][$];
			double low_a[$], low_b[$], high_a[$], high_b[$];
			double gain_low[$], gain_mid[$], gain_high[$];
			int32_t length[$];
			int32_t diffuser_length[4];
			double t60[3];
			double predelay;
			double output_gain;
			double coefficient_low, coefficient_high;
			uint32_t write;
			bool initialized;
			bool sleeping;
			uint32_t quiet_frames;
		}
	]],
		LINES,
		LINE_SIZE,
		PREDELAY_SIZE,
		DIFFUSER_SIZE,
		LINES,
		LINES,
		LINES,
		LINES,
		LINES,
		LINES,
		LINES,
		LINES
	)
	local SIGN_LEFT = {1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1, -1, -1, -1}
	local SIGN_RIGHT = {1, -1, 1, -1, 1, -1, 1, -1, 1, -1, 1, -1, 1, -1, 1, -1}
	local SIGN_INPUT = {1, -1, -1, 1, 1, 1, -1, -1, -1, 1, 1, -1, 1, -1, 1, 1}
	local sign_left = ffi.new("double[16]", SIGN_LEFT)
	local sign_right = ffi.new("double[16]", SIGN_RIGHT)
	local sign_input = ffi.new("double[16]", SIGN_INPUT)
	local lines_out = ffi.new("double[16]")
	local MIN_T60 = 0.05

	function dsp.CreateReverb(sample_rate)
		local reverb = reverb_t()
		local scale = sample_rate / 44100

		for i = 0, LINES - 1 do
			reverb.length[i] = math.min(math.floor(DELAYS[i + 1] * scale + 0.5), LINE_SIZE - 1)
		end

		for i = 0, 3 do
			reverb.diffuser_length[i] = math.min(math.floor(DIFFUSERS[i + 1] * scale + 0.5), DIFFUSER_SIZE - 1)
		end

		reverb.coefficient_low = dsp.OnePoleCoefficient(dsp.LOW_CROSSOVER, sample_rate)
		reverb.coefficient_high = dsp.OnePoleCoefficient(dsp.HIGH_CROSSOVER, sample_rate)
		return reverb
	end

	function dsp.GetReverbSettleSamples(reverb)
		return reverb.length[LINES - 1] + PREDELAY_SIZE
	end

	local function update_gains(reverb, sample_rate)
		local energy = 0

		for i = 0, LINES - 1 do
			local seconds = -3 * reverb.length[i] / sample_rate
			local low, mid, high = dsp.WarpBandGains(
				10 ^ (seconds / reverb.t60[0]),
				10 ^ (seconds / reverb.t60[1]),
				10 ^ (seconds / reverb.t60[2])
			)
			local bound = dsp.BandGainBound(low, mid, high)
			local peak = math.max(low, mid, high)

			if bound > peak then
				low = low * peak / bound
				mid = mid * peak / bound
				high = high * peak / bound
			end

			reverb.gain_low[i] = low
			reverb.gain_mid[i] = mid
			reverb.gain_high[i] = high
			energy = energy + mid * mid
		end

		energy = energy / LINES
		reverb.output_gain = 1.05 * math.sqrt((1 - energy) / energy)
	end

	function dsp.ProcessReverb(reverb, input, output, frames, sample_rate, t60_low, t60_mid, t60_high, predelay)
		local silent = true

		for i = 0, frames - 1 do
			if input[i] ~= 0 then
				silent = false

				break
			end
		end

		if silent and reverb.sleeping then return end

		reverb.sleeping = false
		reverb.quiet_frames = silent and math.min(reverb.quiet_frames + frames, 0x7FFFFFFF) or 0
		t60_low = math.max(t60_low, MIN_T60)
		t60_mid = math.max(t60_mid, MIN_T60)
		t60_high = math.max(t60_high, MIN_T60)
		predelay = math.clamp(predelay * sample_rate, 1, PREDELAY_SIZE - frames - 4)

		if not reverb.initialized then
			reverb.initialized = true
			reverb.t60[0] = t60_low
			reverb.t60[1] = t60_mid
			reverb.t60[2] = t60_high
			reverb.predelay = predelay
		else
			local k = 1 - math.exp(-frames / (0.25 * sample_rate))
			reverb.t60[0] = math.exp(math.lerp(k, math.log(reverb.t60[0]), math.log(t60_low)))
			reverb.t60[1] = math.exp(math.lerp(k, math.log(reverb.t60[1]), math.log(t60_mid)))
			reverb.t60[2] = math.exp(math.lerp(k, math.log(reverb.t60[2]), math.log(t60_high)))
		end

		update_gains(reverb, sample_rate)
		local predelay_start = reverb.predelay
		local predelay_step = (predelay - predelay_start) / frames
		predelay_step = math.clamp(predelay_step, -0.5, 0.5)
		reverb.predelay = predelay_start + predelay_step * frames
		local ca = reverb.coefficient_low
		local cb = reverb.coefficient_high
		local output_gain = reverb.output_gain
		local write = reverb.write
		local lines = reverb.lines
		local length = reverb.length
		local low_a, low_b, high_a, high_b = reverb.low_a, reverb.low_b, reverb.high_a, reverb.high_b
		local gain_low, gain_mid, gain_high = reverb.gain_low, reverb.gain_mid, reverb.gain_high
		local predelay_line = reverb.predelay_line
		local diffusers = reverb.diffusers
		local diffuser_length = reverb.diffuser_length
		local antidenormal = 1e-20
		local tail_energy = 0

		for i = 0, frames - 1 do
			predelay_line[bit.band(write, PREDELAY_MASK)] = input[i]
			local x = dsp.ReadLinear(predelay_line, PREDELAY_MASK, write - predelay_start - predelay_step * (i + 1))

			for d = 0, 3 do
				local line = diffusers[d]
				local delayed = line[bit.band(write - diffuser_length[d], DIFFUSER_MASK)]
				local y = delayed - DIFFUSER_GAIN * x
				line[bit.band(write, DIFFUSER_MASK)] = x + DIFFUSER_GAIN * y
				x = y
			end

			x = x * 0.25 + antidenormal
			antidenormal = -antidenormal
			local left = 0
			local right = 0

			for j = 0, LINES - 1 do
				local y = lines[j][bit.band(write - length[j], LINE_MASK)]
				local la = low_a[j] + ca * (y - low_a[j])
				local lb = low_b[j] + ca * (la - low_b[j])
				local ha = high_a[j] + cb * (y - high_a[j])
				local hb = high_b[j] + cb * (ha - high_b[j])
				low_a[j] = la
				low_b[j] = lb
				high_a[j] = ha
				high_b[j] = hb
				local gh = gain_high[j]
				local gm = gain_mid[j]
				y = gh * y + (gm - gh) * hb + (gain_low[j] - gm) * lb
				lines_out[j] = y
				left = left + sign_left[j] * y
				right = right + sign_right[j] * y
			end

			local span = 1

			while span < LINES do
				for base = 0, LINES - 1, span * 2 do
					for k = base, base + span - 1 do
						local a = lines_out[k]
						local b = lines_out[k + span]
						lines_out[k] = a + b
						lines_out[k + span] = a - b
					end
				end

				span = span * 2
			end

			for j = 0, LINES - 1 do
				lines[j][bit.band(write, LINE_MASK)] = lines_out[j] * 0.25 + sign_input[j] * x
			end

			tail_energy = tail_energy + left * left + right * right
			output[i * 2] = output[i * 2] + left * output_gain
			output[i * 2 + 1] = output[i * 2 + 1] + right * output_gain
			write = write + 1
		end

		reverb.write = write
		reverb.sleeping = reverb.quiet_frames > dsp.GetReverbSettleSamples(reverb) and
			tail_energy * output_gain * output_gain < 1e-14 * frames
	end
end

return dsp
