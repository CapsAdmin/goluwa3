local system = require("system")
local benchmark = {}

function benchmark.Run(name, iterations, func)
	local start = system.GetTime()

	for _ = 1, iterations do
		func()
	end

	local elapsed = system.GetTime() - start
	local ops_per_sec = iterations / elapsed
	local ns_per_op = (elapsed / iterations) * 1e9
	io.write(string.format("%-40s %10.0f ops/sec  %8.2f ns/op\n", name, ops_per_sec, ns_per_op))
	return elapsed
end

return benchmark
