local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")

event.AddListener("Update", "window_title", function(dt)
	if wait(1) then
		system.GetWindow():SetTitle("FPS: " .. math.round(1 / system.GetFrameTime()))
	end
end)
