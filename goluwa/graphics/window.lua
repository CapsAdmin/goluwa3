local window = require("window")
local event = require("event")
local system = require("system")
local wnd = window.Open()
wnd:SetMouseTrapped(true)

event.AddListener("Update", "window_title", function(dt)
	if wait(1) then
		wnd:SetTitle("FPS: " .. math.round(1 / system.GetFrameTime()))
	end
end)

return wnd
