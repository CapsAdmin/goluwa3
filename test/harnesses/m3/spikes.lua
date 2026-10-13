-- find what makes slow frames: per frame times of listeners/functions, print the worst frames with their top offenders
local m3 = import("test/harnesses/m3/harness.lua")
local pvars = import("goluwa/cli/pvars.lua")
local system = import("goluwa/system.lua")
local event = import("goluwa/event.lua")
local render = import("goluwa/render/render.lua")
local gpu_timing = import("goluwa/render/gpu_timing.lua")
local frames = tonumber(os.getenv("M3_FRAMES") or "600")
local measuring = false
local cur = {}
local function add(key, dt) cur[key] = (cur[key] or 0) + dt end
local stack = {}
local old_begin, old_end = gpu_timing.BeginScope, gpu_timing.EndScope
gpu_timing.BeginScope = function(cmd, name) stack[#stack + 1] = {name, system.GetTime()} return old_begin(cmd, name) end
gpu_timing.EndScope = function(cmd, name)
	local top = stack[#stack] stack[#stack] = nil
	if top and measuring then add("scope " .. top[1], system.GetTime() - top[2]) end
	return old_end(cmd, name)
end
local function wrap_listeners()
	for event_type, list in pairs(event.active) do
		for _, config in ipairs(list) do
			if not config.s_wrapped then
				config.s_wrapped = true
				local cb = config.callback
				local key = "ev " .. tostring(event_type) .. "->" .. tostring(config.id)
				config.callback = function(...)
					if not measuring then return cb(...) end
					local t = system.GetTime()
					local a, b, c, d = cb(...)
					add(key, system.GetTime() - t)
					return a, b, c, d
				end
			end
		end
	end
end
local culling = os.getenv("M3_CULLING") ~= "0"
if os.getenv("M3_GC_PAUSE") then collectgarbage("setpause", tonumber(os.getenv("M3_GC_PAUSE"))) end
if os.getenv("M3_GC_STEPMUL") then collectgarbage("setstepmul", tonumber(os.getenv("M3_GC_STEPMUL"))) end
local start, n
local records = {}
local prev
m3.Run(function(view, now)
	start = start or now
	if not measuring then
		if now - start < 1 then pvars.SetSession("r_feature_culling", culling) pvars.SetSession("lod_level", tonumber(os.getenv("M3_LOD") or "-1")) end
		if now - start > 9 then wrap_listeners() end
		if now - start > 10 then measuring = true n = 0 prev = system.GetTime() cur = {} if os.getenv("M3_NOGC") then collectgarbage("stop") end end
		return
	end
	local t = system.GetTime()
	local dt = t - prev
	prev = t
	n = n + 1
	records[#records + 1] = {dt = dt, info = cur, index = n}
	cur = {}
	if n >= frames then
		local sorted = {}
		for _, r in ipairs(records) do sorted[#sorted + 1] = r end
		table.sort(sorted, function(a, b) return a.dt > b.dt end)
		local hist = {}
		for _, r in ipairs(records) do local b = math.floor(r.dt * 1000 / 2) * 2 hist[b] = (hist[b] or 0) + 1 end
		local keys = {} for k in pairs(hist) do keys[#keys + 1] = k end table.sort(keys)
		local parts = {} for _, k in ipairs(keys) do parts[#parts + 1] = string.format("%d-%dms:%d", k, k + 2, hist[k]) end
		print("SPIKE histogram " .. table.concat(parts, " "))
		local total = 0 for _, r in ipairs(records) do total = total + r.dt end
		local over = 0 for _, r in ipairs(records) do if r.dt > 0.018 then over = over + 1 end end
		local by_dt = {} for _, r in ipairs(records) do by_dt[#by_dt + 1] = r.dt end table.sort(by_dt)
		print(string.format("SPIKE summary avg %.2f p50 %.2f p95 %.2f p99 %.2f max %.1f ms, frames >18ms: %d of %d, heap %.0f MB", total / #records * 1000, by_dt[math.ceil(#by_dt * 0.5)] * 1000, by_dt[math.ceil(#by_dt * 0.95)] * 1000, by_dt[math.ceil(#by_dt * 0.99)] * 1000, by_dt[#by_dt] * 1000, over, #records, collectgarbage("count") / 1024))
		-- median profile for comparison
		local median = {}
		for i = 1, #records do for k, v in pairs(records[i].info) do median[k] = (median[k] or 0) + v end end
		for k in pairs(median) do median[k] = median[k] / #records end
		for i = 1, 6 do
			local r = sorted[i]
			local rows = {}
			for k, v in pairs(r.info) do rows[#rows + 1] = {k, v, v - (median[k] or 0)} end
			table.sort(rows, function(a, b) return a[3] > b[3] end)
			local parts = {}
			for j = 1, math.min(14, #rows) do parts[#parts + 1] = string.format("%s=%.1f(+%.1f)", rows[j][1], rows[j][2] * 1000, rows[j][3] * 1000) end
			print(string.format("SPIKE frame#%d %.1f ms: %s", r.index, r.dt * 1000, table.concat(parts, "  ")))
		end
		local idxs = {}
		for _, r in ipairs(records) do if r.dt > 0.02 then idxs[#idxs + 1] = r.index end end
		print("SPIKE slow frame indices: " .. table.concat(idxs, ","))
		return false
	end
end)
