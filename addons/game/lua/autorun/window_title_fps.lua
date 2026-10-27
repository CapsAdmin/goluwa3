local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local render = import("goluwa/render/render.lua")
local gpu_timing = import("goluwa/render/gpu_timing.lua")
local accumulated_time = 0
local accumulated_frames = 0
local accumulated_gpu_ms = 0
local wait_at_start = 0

event.AddListener("Update", "window_title", function(dt)
	if not system.IsWindowOpen(index) then return end

	accumulated_time = accumulated_time + dt
	accumulated_frames = accumulated_frames + 1
	accumulated_gpu_ms = accumulated_gpu_ms + gpu_timing.GetMilliseconds("gpu_total")

	if accumulated_time >= 1 then
		local wait = render.GetWaitTime()
		local cpu_ms = (accumulated_time - (wait - wait_at_start)) / accumulated_frames * 1000
		system.GetWindow():SetTitle(
			string.format(
				"FPS: %d | cpu: %.2f ms | gpu: %.2f ms",
				math.round(accumulated_frames / accumulated_time),
				cpu_ms,
				accumulated_gpu_ms / accumulated_frames
			)
		)
		wait_at_start = wait
		accumulated_time = 0
		accumulated_frames = 0
		accumulated_gpu_ms = 0
	end
end)
