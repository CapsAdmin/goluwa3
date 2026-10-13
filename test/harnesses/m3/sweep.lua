-- sweeps pvar variants inside one process: M3_SWEEP="name=key:val,key:val;name2=..." ; first variant is repeated at the end
local m3 = import("test/harnesses/m3/harness.lua")
local pvars = import("goluwa/cli/pvars.lua")
local system = import("goluwa/system.lua")
local gpu_timing = import("goluwa/render/gpu_timing.lua")
local culling = os.getenv("M3_CULLING") ~= "0"
local frames = tonumber(os.getenv("M3_FRAMES") or "120")
local warm_frames = tonumber(os.getenv("M3_WARMF") or "40")
local variants = {}
for spec in (os.getenv("M3_SWEEP") or "base="):gmatch("[^;]+") do
	local name, rest = spec:match("^([^=]+)=(.*)$")
	local sets = {}
	for kv in rest:gmatch("[^,]+") do
		local k, v = kv:match("^([^:]+):(.+)$")
		if v == "true" then v = true elseif v == "false" then v = false else v = tonumber(v) or v end
		sets[#sets + 1] = {k, v}
	end
	variants[#variants + 1] = {name = name, sets = sets}
end
variants[#variants + 1] = {name = variants[1].name .. " (again)", sets = variants[1].sets}
local cpu = {}
local stack = {}
local old_begin, old_end = gpu_timing.BeginScope, gpu_timing.EndScope
gpu_timing.BeginScope = function(cmd, name) stack[#stack + 1] = {name, system.GetTime()} return old_begin(cmd, name) end
gpu_timing.EndScope = function(cmd, name)
	local top = stack[#stack] stack[#stack] = nil
	if top then cpu[top[1]] = (cpu[top[1]] or 0) + system.GetTime() - top[2] end
	return old_end(cmd, name)
end
local idx, n, state = 0, 0, "start"
local gpu_prev, gpu_sum, times, prev
local defaults = {}
local started
local function apply(v)
	-- restore everything changed so far, then apply
	for k, val in pairs(defaults) do pvars.SetSession(k, val) end
	for _, kv in ipairs(v.sets) do
		if defaults[kv[1]] == nil then defaults[kv[1]] = pvars.Get(kv[1]) end
		pvars.SetSession(kv[1], kv[2])
	end
end
m3.Run(function(view, now)
	if state == "start" then
		pvars.SetSession("r_feature_culling", culling)
		pvars.SetSession("lod_level", tonumber(os.getenv("M3_LOD") or "-1"))
		started = started or now
		if now - started < 10 then return end
		idx = 1 apply(variants[1]) state = "warm" n = 0
		return
	end
	n = n + 1
	if state == "warm" then
		if n >= warm_frames then
			state = "measure" n = 0 gpu_prev, gpu_sum, times = {}, {}, {} table.clear(cpu) prev = system.GetTime()
		end
		return
	end
	local t = system.GetTime()
	times[#times + 1] = t - prev
	prev = t
	local names = gpu_timing.GetScopeNames()
	for i = 1, #names do
		local ms = gpu_timing.GetRawMilliseconds(names[i])
		if gpu_prev[names[i]] ~= ms then gpu_prev[names[i]] = ms gpu_sum[names[i]] = (gpu_sum[names[i]] or 0) + ms end
	end
	if n >= frames then
		local total = 0
		for _, x in ipairs(times) do total = total + x end
		table.sort(times)
		local g = function(name) return (gpu_sum[name] or 0) / n end
		local shadows = 0
		for k, v in pairs(gpu_sum) do if k:find("^shadow_") then shadows = shadows + v / n end end
		print(string.format("SWEEP %-34s frame %6.2f (p95 %6.2f) | gpu %6.2f lighting %5.2f ddgi_shade %5.2f transl_acc %5.2f reflections %5.2f gbuf %5.2f shadows %5.2f | cpu %6.2f",
			variants[idx].name, total / n * 1000, times[math.ceil(n * 0.95)] * 1000, g("gpu_frame"), g("lighting"), g("ddgi_shade"), g("translucent_accumulate"), g("reflections"), g("gbuffer"), shadows, (cpu.gpu_frame or 0) / n * 1000))
		idx = idx + 1
		if idx > #variants then return false end
		apply(variants[idx]) state = "warm" n = 0
	end
end)
