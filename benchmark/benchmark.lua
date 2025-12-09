local system = require("system")
local get_time = system.GetTime
local benchmark = {}
local timer_overhead = 0

function benchmark.Run(name, func, timeout)
	collectgarbage("collect")
	local elapsed = 0
	local sample = 0
	local samples = {n = 0}
	local time, diff_time
	local hit = 0

	for _ = 1, 10000000 do
		time = get_time()
		func()
		diff_time = get_time() - time - timer_overhead
		elapsed = elapsed + diff_time
		sample = sample + 1

		if sample > 56 then
			samples.n = samples.n + 1
			samples[samples.n] = elapsed / sample

			if samples.n >= 2 then
				local diff = samples[samples.n] - samples[samples.n - 1]

				if math.abs(diff) < 0.0000001 then
					hit = hit + 1

					if hit > 100 then break end
				else
					hit = 0
				end
			end

			elapsed = 0
			sample = 0
		end
	end

	local avg = 0
	local start_idx = math.max(1, samples.n - 99)
	local count = samples.n - start_idx + 1

	for i = start_idx, samples.n do
		avg = avg + samples[i]
	end

	avg = avg / count
	local mean_time_per_op = avg
	local mean_ops_per_sec = 1 / mean_time_per_op
	local ns_per_op = mean_time_per_op * 1e9

	if name then
		io.write(string.format("%-40s %8.2f ns/op  \n", name, ns_per_op))
	end

	return avg
end

timer_overhead = benchmark.Run(nil, function() end, nil, true)
return benchmark
