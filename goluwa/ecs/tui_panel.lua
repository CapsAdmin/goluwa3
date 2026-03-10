local repl = require("repl")
local valid = nil
local TuiPanel = require("ecs.base")("tui_panel", "ecs.components.tui.", function()
	valid = valid or
		{
			-- reuse 2d components
			transform = require("ecs.components.2d.transform"),
			layout = require("ecs.components.2d.layout"),
			-- tui-specific  components
			tui_element = require("ecs.components.tui.tui_element"),
			tui_text = require("ecs.components.tui.tui_text"),
			tui_border = require("ecs.components.tui.tui_border"),
			tui_mouse_input = require("ecs.components.tui.tui_mouse_input"),
			tui_key_input = require("ecs.components.tui.tui_key_input"),
			tui_clickable = require("ecs.components.tui.tui_clickable"),
			tui_resizable = require("ecs.components.tui.tui_resizable"),
			tui_draggable = require("ecs.components.tui.tui_draggable"),
			tui_animation = require("ecs.components.tui.tui_animation"),
		}
	return valid
end)
package.loaded["ecs.tui_panel"] = TuiPanel
local Vec2 = require("structs.vec2")
local event = require("event")
TuiPanel.World = TuiPanel.New(
	{
		ComponentSet = {
			"transform",
			"layout",
			"tui_element",
		},
		layout = {
			Direction = "y",
			GrowWidth = 1,
			GrowHeight = 1,
		},
	}
)
TuiPanel.World:SetName("TuiWorldPanel")
TuiPanel.World.transform:SetPosition(Vec2(1, 1))

local function sync_terminal_size()
	local repl = require("repl")
	local term = repl.GetTerminal()

	if not term then return end

	local w, h = term:GetSize()
	TuiPanel.World.transform:SetSize(Vec2(w, h))
end

sync_terminal_size()

event.AddListener(
	"Update",
	"tui_panel_world_size",
	function()
		sync_terminal_size()
	end,
	{priority = -200}
)

function TuiPanel.Draw(term)
	if TuiPanel.World.tui_element then
		TuiPanel.World.tui_element:DrawRecursive(term)
	end
end

do
	local needs_redraw = true
	local last_term_w, last_term_h = 0, 0

	function TuiPanel.NeedsRedraw()
		needs_redraw = true
	end

	-- Ctrl+C → back to REPL (high priority so it runs before other key handlers)
	event.AddListener(
		"TerminalKeyInput",
		"tui_panel",
		function(key, press, modifiers)
			if key == "c" and modifiers and modifiers.ctrl and press then
				repl.SetEnabled(true)
			end
		end,
		{priority = 100}
	)

	-- Any input marks the UI dirty so it redraws.
	event.AddListener("TerminalMouseInput", "tui_panel", function()
		needs_redraw = true
	end)

	event.AddListener("TerminalMouseMoved", "tui_panel", function()
		needs_redraw = true
	end)

	event.AddListener("TerminalMouseWheel", "tui_panel", function()
		needs_redraw = true
	end)

	-- Animations running → keep redrawing until they finish.
	event.AddListener("TuiAnimating", "tui_panel", function()
		needs_redraw = true
	end)

	event.AddListener("TerminalKeyInput", "tui_panel", function()
		needs_redraw = true
	end)

	-- Resize → update root transform (OnLayoutUpdated will set needs_redraw).
	event.AddListener("TerminalResized", "tui_panel", function(w, h)
		last_term_w, last_term_h = w, h
		root.transform:SetSize(Vec2(w, h))
	end)

	-- ── draw loop ──────────────────────────────────────────────────────────────
	-- Layout auto-updates via its own "Update" listener at priority=-100.
	-- We run at priority=-200 (after layout) so transforms are already settled.
	event.AddListener(
		"Update",
		"tui_panel_draw",
		function()
			local ok, err = pcall(function()
				if repl.GetEnabled() then return end

				if not needs_redraw then return end

				local term = repl.GetTerminal()

				if not term then return end

				needs_redraw = false
				term:BeginFrame()
				term:Clear()
				TuiPanel.Draw(term)
				term:EndFrame()
				term:Flush()
			end)

			if not ok then
				repl.SetEnabled(true)
				teardown()
				print("Error in draw loop:", err)
			end
		end,
		{priority = -200}
	)
end

do
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

	event.AddListener("Update", "tui_panel_events", function()
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
end

return TuiPanel