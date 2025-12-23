local window = require("window")
local event = require("event")
local system = require("system")
local input = require("input")
local wnd = window.Open()
wnd:SetMouseTrapped(false)

event.AddListener("Update", "window_title", function(dt)
	if wait(1) then
		wnd:SetTitle("FPS: " .. math.round(1 / system.GetFrameTime()))
	end
end)

event.AddListener("KeyInput", "escape_shutdown", function(key, press)
	if not press then return end

	if key == "escape" then wnd:SetMouseTrapped(not wnd:GetMouseTrapped()) end
end)

return wnd
