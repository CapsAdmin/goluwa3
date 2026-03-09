local T = require("test.environment")
local ffi = require("ffi")
local ogg = require("codecs.ogg")
local fs = require("fs")
local resource = require("resource")

T.Test("Ogg/Vorbis decoder", function()
	local path = resource.Download("https://github.com/CapsAdmin/goluwa-assets/raw/refs/heads/master/test/ogg/test_sweep.ogg"):Get()
	local data = fs.read_file(path)
	T(data)["~="](nil)
	T(#data)[">"](0)
	local res = assert(ogg.Decode(data))
	T(res.pages)["~="](nil)
	T(#res.pages)[">"](0)
	T(#res.packets)[">"](0)
	-- Verify Vorbis header extraction
	T(res.channels)[">="](1)
	T(res.sample_rate)[">="](8000)
	T(res.vorbis_version)["~="](nil)
	T(res.setup)["~="](nil)
	T(res.setup.codebooks)["~="](nil)
	T(#res.setup.codebooks)[">"](0)
	T(res.setup.floors)["~="](nil)
	T(#res.setup.floors)[">"](0)
	T(res.setup.residues)["~="](nil)
	T(#res.setup.residues)[">"](0)
	T(res.setup.mappings)["~="](nil)
	T(#res.setup.mappings)[">"](0)
	T(res.setup.modes)["~="](nil)
	T(#res.setup.modes)[">"](0)
	-- Verify PCM buffer allocation
	T(res.data)["~="](nil)
	T(type(res.data))["=="]("cdata") -- ffi pointer/buffer
	T(tonumber(res.samples))[">"](0)
	-- Verify sample range and sanity
	local num_samples = tonumber(res.samples)
	local channels = res.channels
	local ptr = ffi.cast("float*", res.data)
	local max_val = 0
	local min_val = 0
	local has_nan = false
	local total_samples = num_samples * channels

	for i = 0, math.min(total_samples - 1, 100000) do
		local v = ptr[i]

		if v ~= v then
			has_nan = true

			break
		end

		if v > max_val then max_val = v end

		if v < min_val then min_val = v end
	end

	if max_val and max_val > 10 then
		error(string.format("max_val is high: %f", max_val))
	end

	if min_val and min_val < -10 then
		error(string.format("min_val is low: %f", min_val))
	end

	local duration = num_samples / res.sample_rate

	T(has_nan)["=="](false)
	T(duration)[">"](0.75)
	T(duration)["<"](1.2)
	T(res.packets_decoded or 0)[">"](0)
	local ptr = ffi.cast("float*", res.data)
	local non_zero = false

	for i = 0, 10000 do
		if math.abs(ptr[i]) > 0.000001 then
			non_zero = true

			break
		end
	end

	T(non_zero)["=="](true)
end)

-- Frequency verification test using a sine sweep
-- Decodes a 100Hz->1000Hz sweep and verifies the dominant frequency
-- increases over time using zero-crossing analysis

T.Test("Ogg/Vorbis sine sweep frequency verification", function()
	local data = fs.read_file(resource.Download("https://github.com/CapsAdmin/goluwa-assets/raw/refs/heads/master/test/ogg/test_sweep.ogg"):Get())
	T(data)["~="](nil)
	local res = assert(ogg.Decode(data))
	T(res.channels)["=="](2)
	T(res.sample_rate)["=="](44100)
	local num_samples = tonumber(res.samples)
	local sr = res.sample_rate
	local ptr = ffi.cast("float*", res.data)
	-- Also load the reference raw PCM for correlation
	local ref_data = fs.read_file(resource.Download("https://github.com/CapsAdmin/goluwa-assets/raw/refs/heads/master/test/ogg/test_sweep_ref.raw"):Get())
	T(ref_data)["~="](nil)
	local ref_ptr = ffi.cast("float*", ref_data)
	local ref_samples = #ref_data / 4 / 2 -- float32, stereo
	-- Extract left channel from decoded output
	local decoded_left = {}

	for i = 0, math.min(num_samples, ref_samples) - 1 do
		decoded_left[i] = ptr[i * 2] -- left channel, interleaved stereo
	end

	-- Extract left channel from reference
	local ref_left = {}

	for i = 0, math.min(num_samples, ref_samples) - 1 do
		ref_left[i] = ref_ptr[i * 2]
	end

	-- Measure dominant frequency via zero-crossing rate in time windows
	-- A sine at freq F has ~2*F zero crossings per second
	local function measure_freq_zc(samples, start_sample, window_size)
		local crossings = 0

		for i = start_sample + 1, start_sample + window_size - 1 do
			local s0 = samples[i - 1] or 0
			local s1 = samples[i] or 0

			if (s0 >= 0 and s1 < 0) or (s0 < 0 and s1 >= 0) then
				crossings = crossings + 1
			end
		end

		return crossings / 2 * (sr / window_size)
	end

	local function measure_rms(samples, start_sample, window_size)
		local sum = 0

		for i = start_sample, start_sample + window_size - 1 do
			local s = samples[i] or 0
			sum = sum + s * s
		end

		return math.sqrt(sum / math.max(window_size, 1))
	end

	local function mean(values)
		local sum = 0

		for i = 1, #values do
			sum = sum + values[i]
		end

		return sum / math.max(#values, 1)
	end

	local function mean_abs_diff(a, b)
		local sum = 0
		local n = math.min(#a, #b)

		for i = 1, n do
			sum = sum + math.abs(a[i] - b[i])
		end

		return sum / math.max(n, 1)
	end

	local function max_abs_diff(a, b)
		local out = 0
		local n = math.min(#a, #b)

		for i = 1, n do
			out = math.max(out, math.abs(a[i] - b[i]))
		end

		return out
	end

	local function mean_adjacent_change(values)
		local sum = 0

		for i = 2, #values do
			sum = sum + math.abs(values[i] - values[i - 1])
		end

		return sum / math.max(#values - 1, 1)
	end

	-- Split into 10 windows and verify frequency increases
	local n_windows = 10
	local usable_samples = math.min(num_samples, ref_samples)
	local window_size = math.floor(usable_samples / n_windows)
	local decoded_freqs = {}
	local ref_freqs = {}

	for w = 0, n_windows - 1 do
		local start = w * window_size
		decoded_freqs[w] = measure_freq_zc(decoded_left, start, window_size)
		ref_freqs[w] = measure_freq_zc(ref_left, start, window_size)
	end

	if _G.DEBUG then
		print("Window | Decoded Freq | Reference Freq | Ratio")
		print("-------+-------------+----------------+------")

		for w = 0, n_windows - 1 do
			local ratio = decoded_freqs[w] / math.max(ref_freqs[w], 1)
			print(
				string.format(
					"  %2d   |  %7.1f Hz  |  %7.1f Hz     | %.3f",
					w,
					decoded_freqs[w],
					ref_freqs[w],
					ratio
				)
			)
		end
	end

	-- Verify: decoded frequencies should roughly track reference frequencies
	-- Allow generous tolerance since Vorbis is lossy
	local good_windows = 0

	for w = 0, n_windows - 1 do
		local ratio = decoded_freqs[w] / math.max(ref_freqs[w], 1)

		if ratio > 0.5 and ratio < 2.0 then good_windows = good_windows + 1 end
	end

	T(good_windows)[">="](n_windows * 0.7) -- at least 70% of windows should track
	-- Verify the sweep goes up: last window freq > first window freq
	T(decoded_freqs[n_windows - 1])[">"](decoded_freqs[0] * 1.5)
	-- Cross-correlation of a small segment to check waveform similarity
	-- Use a segment from the middle of the file where the sweep is well-established
	local mid = math.floor(usable_samples / 2)
	local corr_len = math.min(4096, usable_samples - mid)
	local sum_xy, sum_xx, sum_yy = 0, 0, 0

	for i = 0, corr_len - 1 do
		local x = decoded_left[mid + i] or 0
		local y = ref_left[mid + i] or 0
		sum_xy = sum_xy + x * y
		sum_xx = sum_xx + x * x
		sum_yy = sum_yy + y * y
	end

	local correlation = sum_xy / (math.sqrt(sum_xx * sum_yy) + 1e-10)
	-- For a properly decoded sine sweep, correlation should be positive
	-- (Vorbis is lossy so we can't expect perfect correlation, but it should be > 0)
	T(correlation)[">"](0.1)
	-- Verify volume envelope stays consistent over time and does not flutter.
	-- Measure short-time RMS and compare the normalized envelope to the
	-- reference PCM, which should have a stable sweep amplitude.
	local env_window_size = math.max(64, math.floor(sr * 0.020)) -- 20 ms
	local env_hop_size = math.max(32, math.floor(sr * 0.005)) -- 5 ms
	local decoded_env = {}
	local ref_env = {}

	for start = 0, usable_samples - env_window_size, env_hop_size do
		table.insert(decoded_env, measure_rms(decoded_left, start, env_window_size))
		table.insert(ref_env, measure_rms(ref_left, start, env_window_size))
	end

	T(#decoded_env)[">"](20)
	T(#ref_env)["=="](#decoded_env)
	local decoded_env_mean = mean(decoded_env)
	local ref_env_mean = mean(ref_env)
	local volume_ratio = decoded_env_mean / math.max(ref_env_mean, 1e-9)
	local decoded_env_norm = {}
	local ref_env_norm = {}

	for i = 1, #decoded_env do
		decoded_env_norm[i] = decoded_env[i] / math.max(decoded_env_mean, 1e-9)
		ref_env_norm[i] = ref_env[i] / math.max(ref_env_mean, 1e-9)
	end

	local env_mae = mean_abs_diff(decoded_env_norm, ref_env_norm)
	local env_max_err = max_abs_diff(decoded_env_norm, ref_env_norm)
	local decoded_flutter = mean_adjacent_change(decoded_env_norm)
	local ref_flutter = mean_adjacent_change(ref_env_norm)

	-- Allow some deviation because Vorbis is lossy, but sustained amplitude
	-- modulation should still stay close to the reference envelope.
	T(volume_ratio)[">"](0.2)
	T(env_mae)["<"](0.12)
	T(decoded_flutter)["<"](ref_flutter * 2.5 + 0.02)
end)