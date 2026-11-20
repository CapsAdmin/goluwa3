local system = import("goluwa/system.lua")
local event = import("goluwa/event.lua")
local gpu_timing = import("goluwa/render/gpu_timing.lua")
local store = import("goluwa/render3d/scene/store.lua")
local accel = import("goluwa/render3d/scene/accel.lua")
local meshes = import("goluwa/render3d/scene/meshes.lua")
local instances = import("goluwa/render3d/scene/instances.lua")
local rt = {}
local frame_state = {frame = -1, prepared = -1}

-- producers write their rows on PreSceneBuild, before the scene is built and before any pass of the frame traces it
function rt.PrepareScene(cmd)
	local frame = system.GetFrameNumber()

	if frame_state.prepared == frame then return end

	frame_state.prepared = frame
	event.Call("PreSceneBuild", cmd)
end

function rt.GetTLAS(cmd)
	local frame = system.GetFrameNumber()

	if frame_state.frame == frame then return frame_state.tlas end

	frame_state.frame = frame
	rt.PrepareScene(cmd)
	store.Update()
	accel.Update()
	meshes.Update()
	gpu_timing.BeginScope(cmd, "rt_build", "scene acceleration")
	frame_state.tlas = instances.Build(cmd) or accel.GetPlaceholderTLAS(cmd)
	gpu_timing.EndScope(cmd, "rt_build")
	accel.MarkTLASUsed()

	if not rt.readied and instances.GetCount() > 0 and meshes.GetPendingCount() == 0 then
		rt.readied = true
		event.Call("RTSceneReady")
	end

	return frame_state.tlas
end

-- the last scene built, for producers tracing static surfaces before this frame's build
function rt.GetBuiltTLAS(cmd)
	if not frame_state.tlas then return accel.GetPlaceholderTLAS(cmd) end

	accel.MarkTLASUsed()
	return frame_state.tlas
end

return rt
