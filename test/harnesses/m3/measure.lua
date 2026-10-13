-- lean measurement: avg/p50/p95 frame ms, alloc MB/s, per pass CPU ms (via gpu_timing scope hooks), gpu pass ms
local m3 = import("test/harnesses/m3/harness.lua")
local pvars = import("goluwa/cli/pvars.lua")
local system = import("goluwa/system.lua")
local gpu_timing = import("goluwa/render/gpu_timing.lua")
local culling = os.getenv("M3_CULLING") ~= "0"
local frames = tonumber(os.getenv("M3_FRAMES") or "400")
local warm = tonumber(os.getenv("M3_WARM") or "10")
local yaw = tonumber(os.getenv("M3_YAW") or "0")
local cpu = {}
local stack = {}
local old_begin, old_end = gpu_timing.BeginScope, gpu_timing.EndScope
gpu_timing.BeginScope = function(cmd, name)
	stack[#stack + 1] = {name, system.GetTime()}
	return old_begin(cmd, name)
end
gpu_timing.EndScope = function(cmd, name)
	local top = stack[#stack]
	stack[#stack] = nil
	if top then cpu[top[1]] = (cpu[top[1]] or 0) + system.GetTime() - top[2] end
	return old_end(cmd, name)
end
local start, n, measuring = nil, 0, false
local times = {}
local prev, heap_prev, alloc
local gpu_prev, gpu_sum = {}, {}
m3.Run(function(view, now)
	start = start or now
	if not measuring then
		if now - start < 1 then
			pvars.SetSession("r_feature_culling", culling)
			pvars.SetSession("lod_level", tonumber(os.getenv("M3_LOD") or "-1"))
		end
		if now - start > warm then
			measuring = true
			if os.getenv("M3_NOGC") then collectgarbage("collect") collectgarbage("stop") end
			table.clear(cpu)
			prev = system.GetTime()
			heap_prev, alloc = collectgarbage("count"), 0
		end
		return
	end
	local t = system.GetTime()
	times[#times + 1] = t - prev
	prev = t
	local heap = collectgarbage("count")
	alloc = alloc + math.max(heap - heap_prev, 0)
	heap_prev = heap
	local names = gpu_timing.GetScopeNames()
	for i = 1, #names do
		local ms = gpu_timing.GetRawMilliseconds(names[i])
		if gpu_prev[names[i]] ~= ms then gpu_prev[names[i]] = ms gpu_sum[names[i]] = (gpu_sum[names[i]] or 0) + ms end
	end
	n = n + 1
	if n >= frames then
		local total = 0
		for _, v in ipairs(times) do total = total + v end
		table.sort(times)
		print(string.format("MEASURE avg %.2f ms  p50 %.2f  p95 %.2f  max %.2f  alloc %.1f MB/s", total / n * 1000, times[math.ceil(n * 0.5)] * 1000, times[math.ceil(n * 0.95)] * 1000, times[n] * 1000, alloc / 1024 / total))
		local rows = {}
		for k, v in pairs(cpu) do rows[#rows + 1] = {k, v / n * 1000} end
		table.sort(rows, function(a, b) return a[2] > b[2] end)
		local parts = {}
		for i = 1, math.min(#rows, 9) do parts[#parts + 1] = string.format("%s=%.2f", rows[i][1], rows[i][2]) end
		print("MEASURE cpu(ms/frame): " .. table.concat(parts, "  "))
		rows = {}
		for k, v in pairs(gpu_sum) do rows[#rows + 1] = {k, v / n} end
		table.sort(rows, function(a, b) return a[2] > b[2] end)
		parts = {}
		for i = 1, math.min(#rows, 9) do parts[#parts + 1] = string.format("%s=%.2f", rows[i][1], rows[i][2]) end
		print("MEASURE gpu(ms/frame): " .. table.concat(parts, "  "))
		return false
	end
end, yaw)
