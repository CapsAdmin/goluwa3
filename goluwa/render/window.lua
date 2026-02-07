local window = require("window")
local event = require("event")
local system = require("system")
local input = require("input")
local wnd = window.Open()
wnd:SetMouseTrapped(false)

event.AddListener("WindowLostFocus", "mouse_trap", function(wnd)
	wnd:SetMouseTrapped(false)
end)

return wnd
