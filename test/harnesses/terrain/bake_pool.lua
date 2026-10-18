-- per tile cpu of recording, submitting and waiting for a batch of bakes with the texture pool warm (bake_cost.lua empties it with Finish). SRC=island|lim, PROF=1 writes a profile
-- luajit glw --3d --background lua "./test/harnesses/terrain/bake_pool.lua"
local GetTime = system.GetTime
local terrain
if os.getenv("SRC") == "lim" then
	terrain = import("test/harnesses/terrain/limcore_scene.lua")
else
	import("addons/examples/lua/examples/render3d/island_terrain.lua")
	terrain = _G.island_terrain
end
terrain:Stop()
local source = terrain.Source
local N = 100
local function release(chunk) source:ReleaseChunk(chunk) end
local function run()
	local t0 = GetTime()
	for i = 1, N do
		source:RequestChunk(terrain:BuildTileRequest(0, 300 + i % 8, 30 + math.floor(i / 8)), release)
	end
	local t1 = GetTime()
	source:Submit()
	local t2 = GetTime()
	while source.in_flight[1] do local b = table.remove(source.in_flight, 1) b.fence:Wait() source:CompleteBatch(b) end
	return t1 - t0, t2 - t1, GetTime() - t2
end
run() run()
local a, b, c = 0, 0, 0
for i = 1, 5 do local x, y, z = run() a, b, c = a + x, b + y, c + z end
print(string.format("PER TILE record %.3f ms, submit %.3f ms, wait %.3f ms", a / 5 / N * 1000, b / 5 / N * 1000, c / 5 / N * 1000))
if os.getenv("PROF") then
	PROF.Start("shade", {trace_recorder = false, shutdown = false})
	run() run() run() run()
	PROF.Stop()
	PROF.Summary("storage/logs/jit_profile_shade.glwp", {top_n = 25})
end
system.ShutDown(0)
