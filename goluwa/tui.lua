local repl = require("repl")
local event = require("event")
local system = require("system")
local input = require("input")
local tui = library()
local key_trigger = input.SetupInputEvent("TerminalKey")
local mouse_trigger = input.SetupInputEvent("TerminalMouse")
tui.last_w = tui.last_w or 0
tui.last_h = tui.last_h or 0

local function dispatch(ev)
	if ev.mouse then
		local x, y = ev.x, ev.y

		if ev.action == "moved" then
			event.Call("TerminalMouseMoved", x, y)
			return
		end

		local button = ev.button

		if button == "wheel_up" or button == "wheel_down" then
			local delta = button == "wheel_up" and 1 or -1
			event.Call("TerminalMouseWheel", delta, x, y)
			return
		end

		local press = ev.action == "pressed"
		mouse_trigger(button, press)
		event.Call("TerminalMouseInput", button, press, x, y)
	else
		local key = ev.key

		if not key then return end

		local modifiers = ev.modifiers or {}
		local press = ev.action == nil or ev.action ~= "released"

		if press and #key == 1 and not modifiers.ctrl then
			event.Call("TerminalCharInput", key)
		end

		key_trigger(key, press)
		event.Call("TerminalKeyInput", key, press, modifiers)
	end
end

event.AddListener("Update", "tui_event_loop", function()
	local term = repl.GetTerminal()

	if not term then return end

	if repl.GetEnabled() then return end

	if not term.mouse_enabled then
		term:EnableMouse(true)
		term.mouse_enabled = true
	end

	local w, h = term:GetSize()

	if w ~= tui.last_w or h ~= tui.last_h then
		tui.last_w = w
		tui.last_h = h
		event.Call("TerminalResized", w, h)
	end

	while true do
		local ev = term:ReadEvent()

		if not ev then break end

		dispatch(ev)
	end
end)

return tui
