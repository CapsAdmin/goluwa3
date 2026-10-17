local event = import("goluwa/event.lua")
local startup = import("goluwa/startup.lua")
local scene = import("goluwa/entities/scene.lua")
local scene_bvh = import("goluwa/render3d/scene_bvh.lua")
local scene_loading = import("goluwa/render3d/scene_loading.lua")
local QUIET_TIME = 1.5
local MAX_FRAME_TIME = 0.2
local last_version
local quiet_since
local snapshot

-- the scene is ready once the map load is done, the bvh has stopped changing and frames are fast again
event.AddListener("Update", "startup_ready", function(dt)
	if startup.IsReady() or not scene_bvh.readied then return end

	local now = startup.GetTime()

	if scene_loading.IsLoading() or scene.IsSpawning() or scene_bvh.version ~= last_version then
		last_version = scene_bvh.version
		quiet_since = now
		snapshot = startup.Snapshot()
		return
	end

	if now - quiet_since >= QUIET_TIME and dt < MAX_FRAME_TIME then
		startup.SetReady(quiet_since, snapshot)

		if os.getenv("GOLUWA_STARTUP_REPORT") == "1" then
			logn("[startup]\n", startup.GetReport())
		end
	end
end)
