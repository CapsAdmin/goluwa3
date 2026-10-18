local system = import("goluwa/system.lua")
local store = import("goluwa/render3d/scene/store.lua")
local accel = import("goluwa/render3d/scene/accel.lua")
local meshes = import("goluwa/render3d/scene/meshes.lua")
local instances = import("goluwa/render3d/scene/instances.lua")
local rt = {}
local frame_state = {frame = -1}

-- the top level structure of the scene for this frame, built once per frame by whichever pass asks first. a scene
-- without instances gets an empty one so ray queries have something to bind
function rt.GetTLAS(cmd)
	local frame = system.GetFrameNumber()

	if frame_state.frame == frame then return frame_state.tlas end

	frame_state.frame = frame
	store.Update()
	accel.Update()
	meshes.Update()
	frame_state.tlas = instances.Build(cmd) or accel.GetPlaceholderTLAS(cmd)
	return frame_state.tlas
end

return rt
