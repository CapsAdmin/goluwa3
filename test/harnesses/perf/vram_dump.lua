-- vram of a scene by label, once it has settled: the `vram_dump` rows, every pipeline with whether it drew, the process total
-- from nvidia-smi (the driver's own memory is the difference to the tracked allocations)
-- SCENE=alpine|esther|quarry|<file.lua> AFTER=seconds LIMIT=400 luajit glw --3d --hdr --background --validate lua "./test/harnesses/perf/vram_dump.lua"
if os.getenv("NOGC") then collectgarbage("stop") end
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local commands = import("goluwa/cli/commands.lua")
local vulkan_memory = import("goluwa/render/vulkan/internal/memory.lua")
local scene_loading = import("goluwa/render3d/scene_loading.lua")
local scene = os.getenv("SCENE") or "alpine"
local limit = os.getenv("LIMIT") or "400"
local after = tonumber(os.getenv("AFTER") or (scene == "quarry" and 25 or scene == "esther" and 5 or 15))
local ready_at = nil
event.AddListener("RTSceneReady", "vd_ready", function() ready_at = system.GetTime() end)
if scene == "alpine" then
	import("addons/examples/lua/examples/render3d/alpine_terrain.lua")
elseif scene == "esther" then
	commands.RunString("map esther")
elseif scene == "quarry" then
	commands.RunString("map IA/Quarry")
else
	import(scene)
end
local start = system.GetTime()
local done = false
local draws = {}
local wrapped = false
local function wrap_draws()
	local render3d = import("goluwa/render3d/render3d.lua")
	if wrapped or not render3d.pipelines_i or not render3d.pipelines_i[1] then return end
	wrapped = true
	for _, pipeline in ipairs(render3d.pipelines_i) do
		draws[pipeline.name] = 0
		local original = pipeline.Draw
		pipeline.Draw = function(self, ...)
			draws[self.name] = draws[self.name] + 1
			return original(self, ...)
		end
	end
end
local good = 0
local last = start
event.AddListener("Update", "vram_dump_probe", function()
	local now = system.GetTime()
	wrap_draws()
	if now - last < 0.15 then good = good + 1 else good = 0 end
	last = now
	if done then return end
	if scene == "alpine" then
		if now - start < after then return end
	else
		if not (ready_at and not scene_loading.IsLoading() and good > 60 and now - ready_at > after) then return end
	end
	done = true
	if not os.getenv("NOGC") then collectgarbage() end
	print(string.format("LUA HEAP %.0f MiB", collectgarbage("count") / 1024))
	commands.RunString("vram_dump " .. limit)
	local render3d = import("goluwa/render3d/render3d.lua")
	for _, pipeline in ipairs(render3d.pipelines_i) do
		local on = render3d.IsPipelineEnabled(pipeline.name) and (not pipeline.is_enabled or pipeline.is_enabled())
		print("PIPE " .. pipeline.name .. " " .. (on and "on" or "off") .. " draws=" .. tostring(draws[pipeline.name]))
	end
	local total = 0
	for _, m in pairs(vulkan_memory.Instances) do if m:IsValid() then total = total + tonumber(m.size) end end
	print(string.format("TRACKED %.0f MiB", total / 1048576))
	local pid = io.open("/proc/self/stat"):read("*l"):match("^(%d+)")
	local p = io.popen("nvidia-smi --query-compute-apps=pid,used_memory --format=csv,noheader 2>&1")
	for line in p:read("*a"):gmatch("[^\n]+") do if line:find("^" .. pid .. ",") then print("SMI " .. line) end end
	p:close()
	os.exit(0)
end)
