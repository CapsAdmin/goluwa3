local m3 = import("test/harnesses/m3/harness.lua")
local pvars = import("goluwa/cli/pvars.lua")
local system = import("goluwa/system.lua")
local gpu_timing = import("goluwa/render/gpu_timing.lua")
local culling = os.getenv("M3_CULLING") ~= "0"
local frames = tonumber(os.getenv("M3_FRAMES") or "600")
local tag = os.getenv("M3_TAG") or "m3"
local started, start_time, n = false, nil, 0
local gpu_prev, gpu_sum = {}, {}
local ft_start
m3.Run(function(view, now)
	start_time = start_time or now
	if not started then
		if now - start_time < 1 then pvars.SetSession("r_feature_culling", culling) pvars.SetSession("lod_level", tonumber(os.getenv("M3_LOD") or "-1")) end
		if now - start_time > 10 then
			started = true
			ft_start = system.GetTime()
			PROF.Start(tag, {shutdown = false, trace_recorder = false})
		end
		return
	end
	n = n + 1
	local names = gpu_timing.GetScopeNames()
	for i = 1, #names do
		local ms = gpu_timing.GetRawMilliseconds(names[i])
		if gpu_prev[names[i]] ~= ms then gpu_prev[names[i]] = ms gpu_sum[names[i]] = (gpu_sum[names[i]] or 0) + ms end
	end
	if n >= frames then
		PROF.Stop()
		local dt = system.GetTime() - ft_start
		print(string.format("FRAMES %d in %.2fs = %.2f ms/frame", n, dt, dt / n * 1000))
		local rows = {}
		for k, v in pairs(gpu_sum) do rows[#rows + 1] = {k, v / n} end
		table.sort(rows, function(a, b) return a[2] > b[2] end)
		for i = 1, math.min(#rows, 25) do print(string.format("GPU %-34s %.3f ms", rows[i][1], rows[i][2])) end
		PROF.Summary("storage/logs/jit_profile_" .. tag .. ".glwp", {top_n = 45})
		return false
	end
end)
