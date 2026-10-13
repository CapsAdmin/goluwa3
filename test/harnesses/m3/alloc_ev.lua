-- KB allocated per frame per event listener (GC stopped)
local m3 = import("test/harnesses/m3/harness.lua")
local pvars = import("goluwa/cli/pvars.lua")
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local gpu_timing = import("goluwa/render/gpu_timing.lua")
local totals, calls = {}, {}
local measuring = false
local function wrap_listeners()
	for event_type, list in pairs(event.active) do
		for _, config in ipairs(list) do
			if not config.a_wrapped then
				config.a_wrapped = true
				local cb = config.callback
				local key = "ev " .. tostring(event_type) .. "->" .. tostring(config.id)
				totals[key] = 0 calls[key] = 0
				config.callback = function(...)
					if not measuring then return cb(...) end
					local before = collectgarbage("count")
					local a, b, c, d = cb(...)
					totals[key] = totals[key] + collectgarbage("count") - before
					calls[key] = calls[key] + 1
					return a, b, c, d
				end
			end
		end
	end
end
local start, n
local frames = tonumber(os.getenv("M3_FRAMES") or "200")
local total0
m3.Run(function(view, now)
	start = start or now
	if not measuring then
		if now - start < 1 then pvars.SetSession("r_feature_culling", os.getenv("M3_CULLING") ~= "0") pvars.SetSession("lod_level", -1) end
		if now - start > 9 then wrap_listeners() end
		if now - start > 10 then collectgarbage("collect") collectgarbage("stop") measuring = true n = 0 total0 = collectgarbage("count") end
		return
	end
	n = n + 1
	if n >= frames then
		local total = collectgarbage("count") - total0
		measuring = false
		collectgarbage("restart")
		print(string.format("ALLOCEV total per frame %.1f KB", total / n))
		local keys = {}
		for k in pairs(totals) do if totals[k] > 0 then keys[#keys + 1] = k end end
		table.sort(keys, function(a, b) return totals[a] > totals[b] end)
		for i = 1, math.min(#keys, 16) do print(string.format("ALLOCEV %-60s %8.1f KB/frame %6.1f calls/frame", keys[i], totals[keys[i]] / n, calls[keys[i]] / n)) end
		return false
	end
end)
