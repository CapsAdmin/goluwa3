-- where the cpu blocks: SubmitAndWait, fence waits, swapchain acquire/present, buffer map; per frame
local m3 = import("test/harnesses/m3/harness.lua")
local pvars = import("goluwa/cli/pvars.lua")
local system = import("goluwa/system.lua")
local render = import("goluwa/render/render.lua")
local totals, calls = {}, {}
local measuring = false
local function wrap(tbl, name, label)
	local v = tbl[name]
	if type(v) ~= "function" then print("no function", label) return end
	tbl[name] = function(...)
		if not measuring then return v(...) end
		local t = system.GetTime()
		return (function(...)
			totals[label] = (totals[label] or 0) + system.GetTime() - t
			calls[label] = (calls[label] or 0) + 1
			return ...
		end)(v(...))
	end
end
wrap(render, "SubmitAndWait", "render.SubmitAndWait")
wrap(render, "Submit", "render.Submit")
wrap(render, "BeginFrame", "render.BeginFrame")
wrap(render, "EndFrame", "render.EndFrame")
local frames = tonumber(os.getenv("M3_FRAMES") or "200")
local start, n
local hooked
m3.Run(function(view, now)
	start = start or now
	if not hooked and render.target and render.target.in_flight_fences then
		hooked = true
		local fence_index = getmetatable(render.target.in_flight_fences[1]).__index
		wrap(fence_index, "Wait", "Fence:Wait")
		local sc = render.target.swapchain or render.target.swap_chain
		if sc then
			local sci = getmetatable(sc).__index
			wrap(sci, "GetNextImage", "swapchain.GetNextImage")
			wrap(sci, "Present", "swapchain.Present")
		else print("no swapchain on target") end
		local buf = import("goluwa/render/vulkan/internal/buffer.lua")
		wrap(buf, "Map", "Buffer:Map")
		wrap(buf, "Unmap", "Buffer:Unmap")
	end
	if not measuring then
		if now - start < 1 then
			pvars.SetSession("r_feature_culling", os.getenv("M3_CULLING") ~= "0")
			pvars.SetSession("lod_level", -1)
		end
		if now - start > 10 then measuring = true n = 0 frame_t0 = system.GetTime() end
		return
	end
	n = n + 1
	if n >= frames then
		measuring = false
		local dt = system.GetTime() - frame_t0
		print(string.format("BLOCK frame %.2f ms", dt / n * 1000))
		local keys = {}
		for k in pairs(totals) do keys[#keys + 1] = k end
		table.sort(keys, function(a, b) return totals[a] > totals[b] end)
		for _, k in ipairs(keys) do
			print(string.format("BLOCK %-28s %7.3f ms/frame %7.1f calls/frame %8.1f us/call", k, totals[k] / n * 1000, calls[k] / n, totals[k] / calls[k] * 1e6))
		end
		return false
	end
end)
