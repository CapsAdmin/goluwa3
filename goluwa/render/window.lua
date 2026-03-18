local window = import("goluwa/window.lua")
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local input = import("goluwa/input.lua")
local wnd = window.Open()
wnd:SetMouseTrapped(false)

event.AddListener("WindowLostFocus", "mouse_trap", function(wnd)
	wnd:SetMouseTrapped(false)
end)

return wnd
