local system = import("goluwa/system.lua")
local benchmark_results = import("goluwa/benchmark_results.lua")
local get_time = system.GetTime
local benchmark = {}
benchmark.recorded = {}
local BATCH_SECONDS = 0.002
local MAX_BATCH = 2 ^ 26
local MIN_SAMPLES = 20
local MAX_SAMPLES = 2000

local function time_batch(func, count)
	local start = get_time()

	for _ = 1, count do
		func()
	end

	return get_time() - start
end

local function calibrate(func, warmup)
	local count = 1

	while count < MAX_BATCH and time_batch(func, count) < BATCH_SECONDS do
		count = count * 2
	end

	local start = get_time()

	while get_time() - start < warmup do
		time_batch(func, count)
	end

	return count
end

local function format_time(nanoseconds)
	if nanoseconds >= 1e6 then return string.format("%.3f ms", nanoseconds / 1e6) end

	if nanoseconds >= 1e3 then return string.format("%.3f us", nanoseconds / 1e3) end

	return string.format("%.2f ns", nanoseconds)
end

local function summarize(samples)
	local sorted = {}
	local sum = 0

	for i, sample in ipairs(samples) do
		sorted[i] = sample
		sum = sum + sample
	end

	table.sort(sorted)
	local count = #sorted
	local mean = sum / count
	local variance = 0

	for _, sample in ipairs(sorted) do
		variance = variance + (sample - mean) ^ 2
	end

	return {
		samples = count,
		min = sorted[1],
		median = sorted[math.ceil(count / 2)],
		p95 = sorted[math.ceil(count * 0.95)],
		mean = mean,
		stddev = math.sqrt(variance / count),
	}
end

local function record(key, value, noise, unit)
	benchmark.recorded[#benchmark.recorded + 1] = {key = key, value = value, noise = noise, unit = unit}
end

local function print_stats(name, stats, batch)
	io.write(
		string.format(
			"%-40s %12s/op  +-%4.1f%%  min %s  p95 %s  (%d samples of %d calls)\n",
			name,
			format_time(stats.median * 1e9),
			stats.median > 0 and stats.stddev / stats.median * 100 or 0,
			format_time(stats.min * 1e9),
			format_time(stats.p95 * 1e9),
			stats.samples,
			batch
		)
	)
end

function benchmark.Run(name, func, options)
	options = options or {}
	local time = options.time or 1
	local max_time = options.max_time or 10
	collectgarbage("collect")
	local batch = calibrate(func, options.warmup or 0.2)
	collectgarbage("collect")
	local samples = {}
	local start = get_time()

	while #samples < MAX_SAMPLES do
		local elapsed = get_time() - start

		if elapsed >= max_time or (#samples >= MIN_SAMPLES and elapsed >= time) then
			break
		end

		samples[#samples + 1] = time_batch(func, batch) / batch
	end

	local stats = summarize(samples)
	print_stats(name, stats, batch)
	record(name .. "/median", stats.median * 1e9, stats.stddev * 1e9, "ns")
	return stats
end

function benchmark.Compare(name, variants, options)
	options = options or {}
	local time = options.time or 1
	local max_time = options.max_time or 10
	local warmup = options.warmup or 0.2
	collectgarbage("collect")
	local batches, samples = {}, {}

	for i, variant in ipairs(variants) do
		batches[i] = calibrate(variant.func, warmup)
		samples[i] = {}
	end

	collectgarbage("collect")
	local start = get_time()
	local rounds = 0

	while rounds < MAX_SAMPLES do
		local elapsed = get_time() - start

		if elapsed >= max_time or (rounds >= MIN_SAMPLES and elapsed >= time) then
			break
		end

		rounds = rounds + 1

		for i, variant in ipairs(variants) do
			samples[i][rounds] = time_batch(variant.func, batches[i]) / batches[i]
		end
	end

	io.write(name, "\n")
	local results = {}

	for i, variant in ipairs(variants) do
		results[i] = summarize(samples[i])
		print_stats("  " .. variant.name, results[i], batches[i])
		record(
			name .. "/" .. variant.name .. "/median",
			results[i].median * 1e9,
			results[i].stddev * 1e9,
			"ns"
		)
	end

	for i = 2, #variants do
		local ratios = {}

		for round = 1, rounds do
			ratios[round] = samples[i][round] / samples[1][round]
		end

		local ratio = summarize(ratios)
		local band = math.max(2 * ratio.stddev / math.sqrt(rounds), 0.01)
		local verdict = "same speed"

		if ratio.median - 1 > band then
			verdict = "slower"
		elseif 1 - ratio.median > band then
			verdict = "faster"
		end

		io.write(
			string.format(
				"  %s is %.3fx %s (%+.1f%%, +-%.1f%% standard error)\n",
				variants[i].name,
				ratio.median,
				verdict,
				(ratio.median - 1) * 100,
				ratio.stddev / math.sqrt(rounds) * 100
			)
		)
		record(name .. "/" .. variants[i].name .. "/ratio", ratio.median, ratio.stddev, "x")
		results[i].ratio = ratio.median
	end

	return results
end

function benchmark.Finish(name)
	local results = benchmark_results.New(name)

	for _, entry in ipairs(benchmark.recorded) do
		results:Add(entry.key, entry.value, entry.noise, entry.unit)
	end

	results:Finish()
	system.ShutDown(0)
end

return benchmark
