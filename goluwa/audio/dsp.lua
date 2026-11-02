local ffi = require("ffi")
local dsp = {}
dsp.LOW_CROSSOVER = 500
dsp.HIGH_CROSSOVER = 4000
dsp.BAND_CENTERS = {250, 1500, 8000}
dsp.REVERB_COHERENT_BELOW = 350

function dsp.OnePoleCoefficient(frequency, sample_rate)
	return 1 - math.exp(-2 * math.pi * frequency / sample_rate)
end

function dsp.PeakingCoefficients(out, at, frequency, gain_db, q, sample_rate)
	local a = 10 ^ (gain_db / 40)
	local w = 2 * math.pi * frequency / sample_rate
	local alpha = math.sin(w) / (2 * q)
	local a0 = 1 + alpha / a
	out[at] = (1 + alpha * a) / a0
	out[at + 1] = -2 * math.cos(w) / a0
	out[at + 2] = (1 - alpha * a) / a0
	out[at + 3] = (1 - alpha / a) / a0
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

do
	local POINTS = 48
	local curves = {}

	local function add_point(curve, k, frequency, sample_rate)
		local w = 2 * math.pi * frequency / sample_rate

		for _, pole in ipairs{
			{dsp.LOW_CROSSOVER, "low_re", "low_im"},
			{dsp.HIGH_CROSSOVER, "high_re", "high_im"},
		} do
			local c = dsp.OnePoleCoefficient(pole[1], sample_rate)
			local dr, di = 1 - (1 - c) * math.cos(w), (1 - c) * math.sin(w)
			local d2 = dr * dr + di * di
			local re, im = c * dr / d2, -c * di / d2
			curve[pole[2]][k], curve[pole[3]][k] = re * re - im * im, 2 * re * im
		end
	end

	local function get_curve(sample_rate)
		local curve = curves[sample_rate]

		if curve then return curve end

		curve = {low_re = {}, low_im = {}, high_re = {}, high_im = {}}
		local centers = {low_re = {}, low_im = {}, high_re = {}, high_im = {}}

		for k = 1, POINTS do
			add_point(curve, k, 20 * (sample_rate / 40) ^ ((k - 1) / (POINTS - 1)), sample_rate)
		end

		for band = 1, 3 do
			add_point(centers, band, dsp.BAND_CENTERS[band], sample_rate)
		end

		curve.centers = centers
		curves[sample_rate] = curve
		return curve
	end

	local function magnitude(low, mid, high, curve, k)
		local re = high + (mid - high) * curve.high_re[k] + (low - mid) * curve.low_re[k]
		local im = (mid - high) * curve.high_im[k] + (low - mid) * curve.low_im[k]
		return math.sqrt(re * re + im * im)
	end

	function dsp.FitBandGains(low, mid, high, sample_rate)
		local centers = get_curve(sample_rate).centers
		local gl, gm, gh = dsp.WarpBandGains(low, mid, high)

		for _ = 1, 6 do
			gl = gl * low / magnitude(gl, gm, gh, centers, 1)
			gm = gm * mid / magnitude(gl, gm, gh, centers, 2)
			gh = gh * high / magnitude(gl, gm, gh, centers, 3)
		end

		return gl, gm, gh
	end

	function dsp.BandGainPeak(low, mid, high, sample_rate)
		local curve = get_curve(sample_rate)
		local peak = 0

		for k = 1, POINTS do
			peak = math.max(peak, magnitude(low, mid, high, curve, k))
		end

		return peak
	end
end

dsp.EAR_RATIO = 4
dsp.EAR_ATTACK = 0.03
dsp.EAR_RELEASE = 1
dsp.EAR_KNEE = 10
dsp.EAR_DETECTOR = 0.02
dsp.EAR_MAX_REDUCTION = 36
dsp.EAR_HIGH_SHARE = 0.6
dsp.EAR_LOW_CORNER = 1000
dsp.EAR_WEIGHT_CORNER = 400
dsp.EAR_BASS_CROSSOVER = 300
dsp.EAR_BASS_OFFSET = 6
dsp.EAR_BASS_RATIO = 4
dsp.EAR_BASS_ATTACK = 0.02
dsp.EAR_BASS_RELEASE = 0.6
dsp.EAR_BASS_MAX_REDUCTION = 40
local NEPERS_PER_DB = 0.11512925464970229

function dsp.CreateEar(sample_rate)
	local w0 = 2 * math.pi * dsp.EAR_WEIGHT_CORNER / sample_rate
	local alpha = math.sin(w0) / (2 * 0.7071)
	local a0 = 1 + alpha
	local cos = math.cos(w0)
	return {
		detector = 1 - math.exp(-1 / (sample_rate * dsp.EAR_DETECTOR)),
		attack = 1 - math.exp(-1 / (sample_rate * dsp.EAR_ATTACK)),
		release = 1 - math.exp(-1 / (sample_rate * dsp.EAR_RELEASE)),
		bass_attack = 1 - math.exp(-1 / (sample_rate * dsp.EAR_BASS_ATTACK)),
		bass_release = 1 - math.exp(-1 / (sample_rate * dsp.EAR_BASS_RELEASE)),
		bass_pole = 1 - math.exp(-2 * math.pi * dsp.EAR_BASS_CROSSOVER / sample_rate),
		low_pole = 1 - math.exp(-2 * math.pi * dsp.EAR_LOW_CORNER / sample_rate),
		b0 = (1 + cos) / 2 / a0,
		b1 = -(1 + cos) / a0,
		a1 = -2 * cos / a0,
		a2 = (1 - alpha) / a0,
		energy = 0,
		reduction = 0,
		bass_energy = 0,
		bass_reduction = 0,
		state = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
	}
end

local function soft_reduction(over, knee, slope)
	if over >= knee / 2 then return over * slope end

	if over > -knee / 2 then return (over + knee / 2) ^ 2 / (2 * knee) * slope end

	return 0
end

-- two stages on the mix. The bass (below 300 Hz) has its own rms and gain: it is most of the energy of a blast and the least audible, it would otherwise decide what the peak limiter does to everything else. The reflex then follows the loudness through a hearing weighted detector (2nd order high pass at 400 Hz, close to A weighting) and takes 1 / ratio of the excess over the threshold in dBFS, in full below 1 kHz and EAR_HIGH_SHARE of it above, through a soft knee
function dsp.ProcessEar(ear, out, frames, threshold)
	local st = ear.state
	local ll1, ll2, lr1, lr2, low_l, low_r, xl1, xl2, yl1, yl2, xr1, xr2 = st[1],
	st[2],
	st[3],
	st[4],
	st[5],
	st[6],
	st[7],
	st[8],
	st[9],
	st[10],
	st[11],
	st[12]
	local yr1, yr2 = ear.yr1 or 0, ear.yr2 or 0
	local detector, b0, b1, a1, a2 = ear.detector, ear.b0, ear.b1, ear.a1, ear.a2
	local energy, reduction, bass_energy, bass_reduction = ear.energy, ear.reduction, ear.bass_energy, ear.bass_reduction
	local slope = 1 - 1 / dsp.EAR_RATIO
	local bass_slope = 1 - 1 / dsp.EAR_BASS_RATIO
	local bass_threshold = threshold + dsp.EAR_BASS_OFFSET
	local knee, share = dsp.EAR_KNEE, dsp.EAR_HIGH_SHARE
	local deepest = 0

	for i = 0, frames - 1 do
		local left, right = out[i * 2], out[i * 2 + 1]
		ll1, lr1 = ll1 + ear.bass_pole * (left - ll1), lr1 + ear.bass_pole * (right - lr1)
		ll2, lr2 = ll2 + ear.bass_pole * (ll1 - ll2), lr2 + ear.bass_pole * (lr1 - lr2)
		bass_energy = bass_energy + detector * (0.5 * (ll2 * ll2 + lr2 * lr2) - bass_energy)
		local target = soft_reduction(10 * math.log10(bass_energy + 1e-12) - bass_threshold, 0, bass_slope)

		if target > dsp.EAR_BASS_MAX_REDUCTION then
			target = dsp.EAR_BASS_MAX_REDUCTION
		end

		bass_reduction = bass_reduction + (
				target > bass_reduction and
				ear.bass_attack or
				ear.bass_release
			) * (
				target - bass_reduction
			)
		local bass_gain = math.exp(-bass_reduction * NEPERS_PER_DB)
		left, right = left - ll2 + ll2 * bass_gain, right - lr2 + lr2 * bass_gain
		local hl = b0 * left + b1 * xl1 + b0 * xl2 - a1 * yl1 - a2 * yl2
		xl2, xl1, yl2, yl1 = xl1, left, yl1, hl
		local hr = b0 * right + b1 * xr1 + b0 * xr2 - a1 * yr1 - a2 * yr2
		xr2, xr1, yr2, yr1 = xr1, right, yr1, hr
		energy = energy + detector * (0.5 * (hl * hl + hr * hr) - energy)
		target = soft_reduction(10 * math.log10(energy + 1e-12) - threshold, knee, slope)

		if target > dsp.EAR_MAX_REDUCTION then target = dsp.EAR_MAX_REDUCTION end

		reduction = reduction + (
				target > reduction and
				ear.attack or
				ear.release
			) * (
				target - reduction
			)
		local gain_low = math.exp(-reduction * NEPERS_PER_DB)
		local gain_high = math.exp(-reduction * share * NEPERS_PER_DB)
		low_l, low_r = low_l + ear.low_pole * (left - low_l), low_r + ear.low_pole * (right - low_r)
		out[i * 2] = gain_high * left + (gain_low - gain_high) * low_l
		out[i * 2 + 1] = gain_high * right + (gain_low - gain_high) * low_r

		if reduction > deepest then deepest = reduction end
	end

	st[1], st[2], st[3], st[4], st[5], st[6], st[7], st[8], st[9], st[10], st[11], st[12] = ll1, ll2, lr1, lr2, low_l, low_r, xl1, xl2, yl1, yl2, xr1, xr2
	ear.yr1, ear.yr2 = yr1, yr2
	ear.energy, ear.reduction, ear.bass_energy, ear.bass_reduction = energy, reduction, bass_energy, bass_reduction
	return deepest
end

dsp.LIMITER_CEILING = 0.9
dsp.LIMITER_LOOKAHEAD = 0.002
dsp.LIMITER_RELEASE = 0.2

function dsp.CreateLimiter(sample_rate)
	local length = math.max(math.floor(sample_rate * dsp.LIMITER_LOOKAHEAD), 2)
	local limiter = {
		length = length,
		delay_left = ffi.new("float[?]", length - 1),
		delay_right = ffi.new("float[?]", length - 1),
		delay_position = 0,
		deque_gain = ffi.new("float[?]", length),
		deque_time = ffi.new("double[?]", length),
		deque_first = 0,
		deque_size = 0,
		average = ffi.new("float[?]", length),
		average_position = 0,
		average_sum = length,
		release = 1 - math.exp(-1 / (sample_rate * dsp.LIMITER_RELEASE)),
		gain = 1,
		time = 0,
	}

	for i = 0, length - 1 do
		limiter.average[i] = 1
	end

	return limiter
end

function dsp.ProcessLimiter(limiter, out, frames)
	local ceiling = dsp.LIMITER_CEILING
	local length = limiter.length
	local delay_length = length - 1
	local delay_left, delay_right = limiter.delay_left, limiter.delay_right
	local delay_position = limiter.delay_position
	local deque_gain, deque_time = limiter.deque_gain, limiter.deque_time
	local first, size = limiter.deque_first, limiter.deque_size
	local average, average_position, average_sum = limiter.average, limiter.average_position, limiter.average_sum
	local release = limiter.release
	local gain = limiter.gain
	local time = limiter.time
	local lowest = 1

	for i = 0, frames - 1 do
		local left = out[i * 2]
		local right = out[i * 2 + 1]
		local peak = math.max(math.abs(left), math.abs(right))
		local needed = peak > ceiling and ceiling / peak or 1

		if size > 0 and deque_time[first] <= time - length then
			first = first + 1 == length and 0 or first + 1
			size = size - 1
		end

		while size > 0 do
			local last = (first + size - 1) % length

			if deque_gain[last] < needed then break end

			size = size - 1
		end

		local slot = (first + size) % length
		deque_gain[slot] = needed
		deque_time[slot] = time
		size = size + 1
		local held = deque_gain[first]
		average_sum = average_sum + held - average[average_position]
		average[average_position] = held
		average_position = average_position + 1 == length and 0 or average_position + 1
		local target = average_sum / length

		if target < gain then
			gain = target
		else
			gain = gain + (target - gain) * release
		end

		if gain < lowest then lowest = gain end

		local delayed_left = delay_left[delay_position]
		local delayed_right = delay_right[delay_position]
		delay_left[delay_position] = left
		delay_right[delay_position] = right
		delay_position = delay_position + 1 == delay_length and 0 or delay_position + 1
		out[i * 2] = delayed_left * gain
		out[i * 2 + 1] = delayed_right * gain
		time = time + 1
	end

	limiter.delay_position = delay_position
	limiter.deque_first, limiter.deque_size = first, size
	limiter.average_position, limiter.average_sum = average_position, average_sum
	limiter.gain = gain
	limiter.time = time
	return lowest
end

function dsp.MeasureLoudness(data, frames, channels, sample_rate)
	local k = math.tan(math.pi * 1681.974450955533 / sample_rate)
	local q = 0.7071752369554196
	local vh = 10 ^ (3.999843853973347 / 20)
	local vb = vh ^ 0.4996667741545416
	local a0 = 1 + k / q + k * k
	local sb0 = (vh + vb * k / q + k * k) / a0
	local sb1 = 2 * (k * k - vh) / a0
	local sb2 = (vh - vb * k / q + k * k) / a0
	local sa1 = 2 * (k * k - 1) / a0
	local sa2 = (1 - k / q + k * k) / a0
	k = math.tan(math.pi * 38.13547087602444 / sample_rate)
	q = 0.5003270373238773
	a0 = 1 + k / q + k * k
	local ha1 = 2 * (k * k - 1) / a0
	local ha2 = (1 - k / q + k * k) / a0
	local block = math.max(math.floor(sample_rate * 0.1), 1)
	local block_count = math.ceil(frames / block)
	local energy = {}

	for i = 1, block_count + 3 do
		energy[i] = 0
	end

	for channel = 0, channels - 1 do
		local x1, x2, y1, y2, z1, z2 = 0, 0, 0, 0, 0, 0
		local index, filled, sum = 1, 0, 0

		for i = 0, frames - 1 do
			local x = data[i * channels + channel]
			local y = sb0 * x + sb1 * x1 + sb2 * x2 - sa1 * y1 - sa2 * y2
			local z = y - 2 * y1 + y2 - ha1 * z1 - ha2 * z2
			x2, x1, y2, y1, z2, z1 = x1, x, y1, y, z1, z
			sum = sum + z * z
			filled = filled + 1

			if filled == block then
				energy[index] = energy[index] + sum
				index, filled, sum = index + 1, 0, 0
			end
		end

		energy[index] = energy[index] + sum
	end

	local loudest = 0

	for i = 1, math.max(block_count - 3, 1) do
		loudest = math.max(loudest, energy[i] + energy[i + 1] + energy[i + 2] + energy[i + 3])
	end

	return -0.691 + 10 * math.log10(math.max(loudest / (block * 4), 1e-12))
end

do
	local LINES = 16
	dsp.REVERB_LINES = LINES
	local LINE_SIZE = 16384
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
	local mean_delay = 0

	for _, delay in ipairs(DELAYS) do
		mean_delay = mean_delay + delay / #DELAYS
	end

	dsp.REVERB_MEAN_DELAY = mean_delay / 44100
	local SCALE_STEPS = {1, 1.25, 1.5, 2, 2.5, 3, 4, 5, 6}
	dsp.REVERB_MIN_SCALE = SCALE_STEPS[1]
	local SCALE_HYSTERESIS = 0.05
	local SIZE_FADE_SECONDS = 0.05
	local PREDELAY_GLIDE = 0.02
	local DIFFUSERS = {142, 107, 379, 277}
	-- the lines reach their decay envelope about one mean line delay (plus the diffuser spread) after the predelay; the diffused input fills that gap
	local DIFFUSER_DELAY = 0.004
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
			double scale, diffusion;
			double delay[$];
			double next_scale;
			double next_delay[$];
			double fade;
			double output_gain;
			double coefficient_low, coefficient_high;
			double coefficient_coherent;
			double coherent[4];
			float pan_line[64];
			double pan[5];
			uint32_t write;
			bool initialized;
			bool sleeping;
			bool fading;
			uint32_t quiet_frames;
			double air_state[$], air_coefficient[$];
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
		LINES,
		LINES,
		LINES,
		(LINES + 2) * 6,
		(LINES + 1) * 6
	)
	local SIGN_LEFT = {1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1, -1, -1, -1}
	local SIGN_RIGHT = {1, -1, 1, -1, 1, -1, 1, -1, 1, -1, 1, -1, 1, -1, 1, -1}
	local SIGN_INPUT = {1, -1, -1, 1, 1, 1, -1, -1, -1, 1, 1, -1, 1, -1, 1, 1}
	local sign_left = ffi.new("double[16]", SIGN_LEFT)
	local sign_right = ffi.new("double[16]", SIGN_RIGHT)
	local sign_input = ffi.new("double[16]", SIGN_INPUT)
	local lines_out = ffi.new("double[16]")
	local MIN_T60 = 0.05
	-- the shallow band filters ripple between band centers; let the ripple ring this much longer than the longest band before shortening all bands
	local RIPPLE_T60 = 1.5
	local COHERENT_BOOST = math.sqrt(2) - 1

	function dsp.CreateReverb(sample_rate)
		local reverb = reverb_t()
		local scale = sample_rate / 44100

		for i = 0, LINES - 1 do
			reverb.length[i] = math.floor(DELAYS[i + 1] * scale + 0.5)
		end

		for i = 0, 3 do
			reverb.diffuser_length[i] = math.min(math.floor(DIFFUSERS[i + 1] * scale + 0.5), DIFFUSER_SIZE - 1)
		end

		for i = 0, (LINES + 1) * 6 - 1 do
			reverb.air_coefficient[i] = 1
		end

		reverb.coefficient_low = dsp.OnePoleCoefficient(dsp.LOW_CROSSOVER, sample_rate)
		reverb.coefficient_high = dsp.OnePoleCoefficient(dsp.HIGH_CROSSOVER, sample_rate)
		reverb.coefficient_coherent = dsp.OnePoleCoefficient(dsp.REVERB_COHERENT_BELOW, sample_rate)
		return reverb
	end

	function dsp.GetReverbSettleSamples(reverb)
		return math.max(reverb.delay[LINES - 1], reverb.next_delay[LINES - 1]) + PREDELAY_SIZE
	end

	local function update_gains(reverb, sample_rate)
		local energy = 0

		for i = 0, LINES - 1 do
			local seconds = -3 * reverb.delay[i] / sample_rate
			local target_low = 10 ^ (seconds / reverb.t60[0])
			local target_mid = 10 ^ (seconds / reverb.t60[1])
			local target_high = 10 ^ (seconds / reverb.t60[2])
			local low, mid, high = dsp.FitBandGains(target_low, target_mid, target_high, sample_rate)
			local response = dsp.BandGainPeak(low, mid, high, sample_rate)
			local peak = 10 ^ (
					seconds / (
						math.max(reverb.t60[0], reverb.t60[1], reverb.t60[2]) * RIPPLE_T60
					)
				)
			local shrink = response > peak and peak / response or 1
			reverb.gain_low[i] = low * shrink
			reverb.gain_mid[i] = mid * shrink
			reverb.gain_high[i] = high * shrink
			energy = energy + (target_mid * shrink) ^ 2
		end

		energy = energy / LINES
		reverb.output_gain = 1.05 * math.sqrt((1 - energy) / energy)
	end

	function dsp.ProcessReverb(
		reverb,
		input,
		output,
		frames,
		sample_rate,
		t60_low,
		t60_mid,
		t60_high,
		predelay,
		scale,
		diffusion,
		concentration,
		gain_left,
		gain_right,
		delay_left,
		delay_right
	)
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
		local nearest = SCALE_STEPS[1]

		for _, step in ipairs(SCALE_STEPS) do
			if math.abs(math.log(scale / step)) < math.abs(math.log(scale / nearest)) then
				nearest = step
			end
		end

		if not reverb.initialized then
			reverb.initialized = true
			reverb.t60[0] = t60_low
			reverb.t60[1] = t60_mid
			reverb.t60[2] = t60_high
			reverb.predelay = predelay
			reverb.scale = nearest
			reverb.diffusion = diffusion
			reverb.pan[0], reverb.pan[1], reverb.pan[2] = concentration, gain_left, gain_right
			reverb.pan[3], reverb.pan[4] = delay_left * sample_rate, delay_right * sample_rate

			for j = 0, LINES - 1 do
				reverb.delay[j] = math.floor(reverb.length[j] * nearest + 0.5)
			end
		else
			local k = 1 - math.exp(-frames / (0.25 * sample_rate))
			reverb.t60[0] = math.exp(math.lerp(k, math.log(reverb.t60[0]), math.log(t60_low)))
			reverb.t60[1] = math.exp(math.lerp(k, math.log(reverb.t60[1]), math.log(t60_mid)))
			reverb.t60[2] = math.exp(math.lerp(k, math.log(reverb.t60[2]), math.log(t60_high)))
			reverb.diffusion = math.lerp(k, reverb.diffusion, diffusion)
			local pan = reverb.pan
			pan[0] = math.lerp(k, pan[0], concentration)
			pan[1] = math.lerp(k, pan[1], gain_left)
			pan[2] = math.lerp(k, pan[2], gain_right)
			pan[3] = math.lerp(k, pan[3], delay_left * sample_rate)
			pan[4] = math.lerp(k, pan[4], delay_right * sample_rate)

			if
				not reverb.fading and
				math.abs(math.log(scale / nearest)) + SCALE_HYSTERESIS < math.abs(math.log(scale / reverb.scale))
			then
				reverb.fading = true
				reverb.fade = 0
				reverb.next_scale = nearest

				for j = 0, LINES - 1 do
					reverb.next_delay[j] = math.floor(reverb.length[j] * nearest + 0.5)
				end
			end
		end

		update_gains(reverb, sample_rate)
		local predelay_start = reverb.predelay
		local predelay_jump = math.abs(predelay - predelay_start) > PREDELAY_GLIDE * frames
		local predelay_step = predelay_jump and 0 or (predelay - predelay_start) / frames
		reverb.predelay = predelay
		local delay = reverb.delay
		local next_delay = reverb.next_delay
		local fading = reverb.fading
		local fade = reverb.fade
		local fade_step = 1 / (SIZE_FADE_SECONDS * sample_rate)
		local keep, take = 1, 0
		local ca = reverb.coefficient_low
		local cb = reverb.coefficient_high
		local output_gain = reverb.output_gain
		local write = reverb.write
		local lines = reverb.lines
		local low_a, low_b, high_a, high_b = reverb.low_a, reverb.low_b, reverb.high_a, reverb.high_b
		local gain_low, gain_mid, gain_high = reverb.gain_low, reverb.gain_mid, reverb.gain_high
		local air_state, air_coefficient = reverb.air_state, reverb.air_coefficient
		local predelay_line = reverb.predelay_line
		local diffusers = reverb.diffusers
		local diffuser_length = reverb.diffuser_length
		local diffuser_gain = DIFFUSER_GAIN * reverb.diffusion
		local onset = dsp.REVERB_MEAN_DELAY * reverb.scale + DIFFUSER_DELAY * reverb.diffusion
		local fill = 1 - math.exp(-13.82 * onset / reverb.t60[1])
		local onset_gain = math.sqrt(fill)
		output_gain = output_gain * math.sqrt(1 - fill)
		local antidenormal = 1e-20
		local tail_energy = 0
		local cc = reverb.coefficient_coherent
		local coherent = reverb.coherent
		local ma, mb, sa, sb = coherent[0], coherent[1], coherent[2], coherent[3]
		local pan_line = reverb.pan_line
		local pan = reverb.pan
		local diffuse_share = math.sqrt(1 - pan[0])
		local directed_left = math.sqrt(pan[0]) * pan[1]
		local directed_right = math.sqrt(pan[0]) * pan[2]
		local pan_delay_left, pan_delay_right = pan[3], pan[4]

		for i = 0, frames - 1 do
			predelay_line[bit.band(write, PREDELAY_MASK)] = input[i]
			local x = dsp.ReadLinear(predelay_line, PREDELAY_MASK, write - predelay_start - predelay_step * (i + 1))

			if predelay_jump then
				local a = (i + 1) / frames
				x = x * (1 - a) + dsp.ReadLinear(predelay_line, PREDELAY_MASK, write - predelay) * a
			end

			if fading then
				local a = math.min(fade + fade_step * (i + 1), 1) * math.pi * 0.5
				keep, take = math.cos(a), math.sin(a)
			end

			local early

			for d = 0, 3 do
				local line = diffusers[d]
				local delayed = line[bit.band(write - diffuser_length[d], DIFFUSER_MASK)]
				local y = delayed - diffuser_gain * x
				line[bit.band(write, DIFFUSER_MASK)] = x + diffuser_gain * y
				early = x
				x = y
			end

			local onset_left, onset_right = x * onset_gain, early * onset_gain
			local oi = LINES * 6

			for k = 0, 5 do
				local c = air_coefficient[oi + k]
				local v = (onset_left - air_state[oi + k]) * c
				onset_left = air_state[oi + k] + v
				air_state[oi + k] = onset_left + v
				v = (onset_right - air_state[oi + 6 + k]) * c
				onset_right = air_state[oi + 6 + k] + v
				air_state[oi + 6 + k] = onset_right + v
			end

			x = x * 0.25 + antidenormal
			antidenormal = -antidenormal
			local left = 0
			local right = 0

			for j = 0, LINES - 1 do
				local line = lines[j]
				local y = line[bit.band(write - delay[j], LINE_MASK)]

				if fading then
					y = y * keep + line[bit.band(write - next_delay[j], LINE_MASK)] * take
				end

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
				local ai = j * 6
				local v = (y - air_state[ai]) * air_coefficient[ai]
				y = air_state[ai] + v
				air_state[ai] = y + v
				v = (y - air_state[ai + 1]) * air_coefficient[ai + 1]
				y = air_state[ai + 1] + v
				air_state[ai + 1] = y + v
				v = (y - air_state[ai + 2]) * air_coefficient[ai + 2]
				y = air_state[ai + 2] + v
				air_state[ai + 2] = y + v
				v = (y - air_state[ai + 3]) * air_coefficient[ai + 3]
				y = air_state[ai + 3] + v
				air_state[ai + 3] = y + v
				v = (y - air_state[ai + 4]) * air_coefficient[ai + 4]
				y = air_state[ai + 4] + v
				air_state[ai + 4] = y + v
				v = (y - air_state[ai + 5]) * air_coefficient[ai + 5]
				y = air_state[ai + 5] + v
				air_state[ai + 5] = y + v
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
			local mid = (left * output_gain + onset_left + right * output_gain + onset_right) * 0.5
			local side = (left * output_gain + onset_left - right * output_gain - onset_right) * 0.5
			ma = ma + cc * (mid - ma)
			local mid_high = mid - ma
			mb = mb + cc * (mid_high - mb)
			mid = mid + COHERENT_BOOST * (mid - mid_high + mb)
			sa = sa + cc * (side - sa)
			local side_high = side - sa
			sb = sb + cc * (side_high - sb)
			side = side_high - sb
			local left_out = mid + side
			pan_line[bit.band(write, 63)] = left_out

			if directed_left > 0 or directed_right > 0 then
				output[i * 2] = output[i * 2] + diffuse_share * left_out + directed_left * dsp.ReadLinear(pan_line, 63, write - pan_delay_left)
				output[i * 2 + 1] = output[i * 2 + 1] + diffuse_share * (
						mid - side
					) + directed_right * dsp.ReadLinear(pan_line, 63, write - pan_delay_right)
			else
				output[i * 2] = output[i * 2] + left_out
				output[i * 2 + 1] = output[i * 2 + 1] + mid - side
			end

			write = write + 1
		end

		coherent[0], coherent[1], coherent[2], coherent[3] = ma, mb, sa, sb
		reverb.write = write

		if fading then
			reverb.fade = fade + fade_step * frames

			if reverb.fade >= 1 then
				local previous_gain = output_gain
				reverb.fading = false
				reverb.scale = reverb.next_scale

				for j = 0, LINES - 1 do
					delay[j] = next_delay[j]
				end

				update_gains(reverb, sample_rate)
				local next_onset = dsp.REVERB_MEAN_DELAY * reverb.scale + DIFFUSER_DELAY * reverb.diffusion
				local carry = previous_gain / (
						reverb.output_gain * math.exp(-6.91 * next_onset / reverb.t60[1])
					)

				for j = 0, LINES - 1 do
					local line = lines[j]

					for k = 0, LINE_SIZE - 1 do
						line[k] = line[k] * carry
					end

					low_a[j] = low_a[j] * carry
					low_b[j] = low_b[j] * carry
					high_a[j] = high_a[j] * carry
					high_b[j] = high_b[j] * carry
				end
			end
		end

		reverb.sleeping = reverb.quiet_frames > dsp.GetReverbSettleSamples(reverb) and
			tail_energy * output_gain * output_gain < 1e-14 * frames
	end
end

return dsp
