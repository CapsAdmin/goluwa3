-- Test to measure timer overhead and precision
local system = require("system")
print("Testing timer overhead and precision...\n")
-- Measure overhead of calling the timer
local iterations = 1000000
local start = system.GetTime()

for i = 1, iterations do
	local _ = system.GetTime()
end

local elapsed = system.GetTime() - start
local overhead_ns = (elapsed / iterations) * 1e9
print(string.format("Timer overhead: %.2f ns per call", overhead_ns))
print(string.format("Total time for %d calls: %.6f seconds", iterations, elapsed))
-- Test timer precision by measuring minimum non-zero delta
print("\nTesting timer precision (measuring minimum time delta)...")
local min_delta = math.huge
local samples = 10000

for i = 1, samples do
	local t1 = system.GetTime()
	local t2 = system.GetTime()
	local delta = t2 - t1

	if delta > 0 and delta < min_delta then min_delta = delta end
end

print(string.format("Minimum measurable time: %.2f ns", min_delta * 1e9))
-- For comparison, estimate clock resolution
local resolution_samples = {}

for i = 1, 100 do
	local t1 = system.GetTime()
	local t2

	repeat
		t2 = system.GetTime()	
	until t2 ~= t1

	table.insert(resolution_samples, (t2 - t1) * 1e9)
end

table.sort(resolution_samples)
local median_resolution = resolution_samples[math.floor(#resolution_samples / 2)]
print(
	string.format("Estimated clock resolution: %.2f ns (median of 100 samples)", median_resolution)
)
