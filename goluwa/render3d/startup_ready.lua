local event = import("goluwa/event.lua")
local startup = import("goluwa/startup.lua")
local scene = import("goluwa/entities/scene.lua")
local scene_rt = import("goluwa/render3d/scene/rt.lua")
local instances = import("goluwa/render3d/scene/instances.lua")
local scene_loading = import("goluwa/render3d/scene_loading.lua")
local pvars = import("goluwa/cli/pvars.lua")
local QUIET_TIME = 1.5
local MAX_FRAME_TIME = 0.2
local last_version
local quiet_since
local snapshot
local normal_gc_pause
pvars.StartGroup("Engine", "Loading", {prefix = "loading_"})
pvars.Setup2{
	key = "r_loading_gc_pause",
	default = 1000,
	type = "number",
	min = 100,
	max = 10000,
	integer = true,
	help = "the garbage collector pause while a map loads, in percent of the heap after the last collection. A load allocates millions of tables and a collection cycle at the default 200 took about 15 percent of the time, at 1000 the heap grows by about a gigabyte more and the load is 10 percent faster",
}
pvars.EndGroup()

event.AddListener("SceneLoad", "startup_gc_pause", function()
	normal_gc_pause = normal_gc_pause or collectgarbage("setpause", pvars.Get("r_loading_gc_pause"))
end)

event.AddListener("Update", "startup_ready", function(dt)
	if startup.IsReady() or not scene_rt.readied then return end

	local now = startup.GetTime()

	if
		scene_loading.IsLoading() or
		scene.IsSpawning() or
		instances.version ~= last_version
	then
		last_version = instances.version
		quiet_since = now
		snapshot = startup.Snapshot()
		return
	end

	if now - quiet_since >= QUIET_TIME and dt < MAX_FRAME_TIME then
		startup.SetReady(quiet_since, snapshot)

		if normal_gc_pause then
			collectgarbage("setpause", normal_gc_pause)
			-- the threshold from the raised pause stays until a cycle ends, start one now
			collectgarbage("restart")
			normal_gc_pause = nil
		end

		if os.getenv("GOLUWA_STARTUP_REPORT") == "1" then
			logn("[startup]\n", startup.GetReport())
		end
	end
end)
