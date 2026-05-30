local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local accumulated_time = 0
local accumulated_frames = 0

event.AddListener("Update", "window_title", function(dt)
	accumulated_time = accumulated_time + dt
	accumulated_frames = accumulated_frames + 1

	if accumulated_time >= 1 and accumulated_frames > 0 then
		local average_frame_time = accumulated_time / accumulated_frames
		local average_fps = accumulated_frames / accumulated_time
		system.GetWindow():SetTitle(
			string.format("FPS: %d | avg: %.1f ms", math.round(average_fps), average_frame_time * 1000)
		)
		accumulated_time = 0
		accumulated_frames = 0
	end
end)
