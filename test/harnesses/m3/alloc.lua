-- KB allocated per frame, per gpu_timing scope (self+children of the scope), and outside any scope
local m3 = import("test/harnesses/m3/harness.lua")
local pvars = import("goluwa/cli/pvars.lua")
local system = import("goluwa/system.lua")
local gpu_timing = import("goluwa/render/gpu_timing.lua")
local culling = os.getenv("M3_CULLING") ~= "0"
local frames = tonumber(os.getenv("M3_FRAMES") or "200")
local alloc = {}
local stack = {}
local measuring = false
local old_begin, old_end = gpu_timing.BeginScope, gpu_timing.EndScope
gpu_timing.BeginScope = function(cmd, name)
	if measuring then stack[#stack + 1] = {name, collectgarbage("count")} end
	return old_begin(cmd, name)
end
gpu_timing.EndScope = function(cmd, name)
	if measuring then
		local top = stack[#stack] stack[#stack] = nil
		if top then alloc[top[1]] = (alloc[top[1]] or 0) + collectgarbage("count") - top[2] end
	end
	return old_end(cmd, name)
end
local start, n
local total0
m3.Run(function(view, now)
	start = start or now
	if not measuring then
		if now - start < 1 then
			pvars.SetSession("r_feature_culling", culling)
			pvars.SetSession("lod_level", tonumber(os.getenv("M3_LOD") or "-1"))
		end
		if now - start > 10 then
			collectgarbage("collect")
			collectgarbage("stop")
			measuring = true n = 0 total0 = collectgarbage("count")
		end
		return
	end
	n = n + 1
	if n >= frames then
		local total = collectgarbage("count") - total0
		collectgarbage("restart")
		print(string.format("ALLOC total %.1f KB/frame", total / n))
		local rows = {}
		for k, v in pairs(alloc) do rows[#rows + 1] = {k, v / n} end
		table.sort(rows, function(a, b) return a[2] > b[2] end)
		for i = 1, math.min(#rows, 14) do print(string.format("ALLOC %-30s %8.1f KB/frame", rows[i][1], rows[i][2])) end
		return false
	end
end)
