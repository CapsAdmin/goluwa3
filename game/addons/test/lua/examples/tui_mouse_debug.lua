HOTRELOAD = false
-- Minimal TUI mouse hit-test debug demo.
-- Run: runfile("game/addons/test/lua/examples/tui_mouse_debug.lua")
-- Move mouse over the terminal and watch the output.
-- Ctrl+C returns to REPL.
local TuiPanel = require("ecs.tui_panel")
local Vec2 = require("structs.vec2")
local Rect = require("structs.rect")
local event = require("event")
local repl = require("repl")
-- ── state ──────────────────────────────────────────────────────────────────
local needs_redraw = true
local lines = {}

local function log(s)
	table.insert(lines, s)

	if #lines > 20 then table.remove(lines, 1) end

	needs_redraw = true
end

-- ── centering container ────────────────────────────────────────────────────
local center = TuiPanel.New(
	{
		Parent = TuiPanel.World,
		ComponentSet = {"transform", "layout"},
		layout = {
			Direction = "y",
			GrowWidth = 1,
			GrowHeight = 1,
			AlignmentX = "center",
			AlignmentY = "center",
		},
	}
)
-- ── outer box with an inner box nested inside ─────────────────────────────
local outer = TuiPanel.New(
	{
		Parent = center,
		ComponentSet = {"transform", "layout", "tui_element", "tui_mouse_input", "tui_border"},
		layout = {
			MinSize = Vec2(60, 24),
			Direction = "y",
			AlignmentX = "center",
			AlignmentY = "center",
			Padding = Rect(2, 2, 2, 2),
		},
		tui_border = {Title = "outer"},
	}
)
outer:SetName("outer")
local inner = TuiPanel.New(
	{
		Parent = outer,
		ComponentSet = {"transform", "layout", "tui_element", "tui_mouse_input", "tui_border"},
		layout = {
			MinSize = Vec2(28, 10),
		},
		tui_border = {Title = "inner"},
	}
)
inner:SetName("inner")
local box_a = outer
local box_b = inner

TuiPanel.World:AddLocalListener("OnLayoutUpdated", function()
	needs_redraw = true
end)

for _, b in ipairs({box_a, box_b}) do
	local name = b:GetName()

	b:AddLocalListener("OnMouseEnter", function()
		log(name .. "  OnMouseEnter")
	end)

	b:AddLocalListener("OnMouseLeave", function()
		log(name .. "  OnMouseLeave")
	end)

	b:AddLocalListener("OnMouseInput", function(btn, press)
		log(string.format("%s  OnMouseInput  %s %s", name, btn, tostring(press)))
	end)

	b:AddLocalListener("OnHover", function(h)
		log(string.format("%s  OnHover  %s", name, tostring(h)))
	end)
end

-- ── track mouse and nearest box rect ──────────────────────────────────────
local mouse_x, mouse_y = 0, 0
local info_a = "?"
local info_b = "?"

event.AddListener("TerminalMouseMoved", "tui_mouse_debug", function(x, y)
	mouse_x, mouse_y = x, y
	local ax1, ay1, ax2, ay2 = box_a.transform:GetWorldRectFast()
	local bx1, by1, bx2, by2 = box_b.transform:GetWorldRectFast()
	info_a = string.format(
		"%.0f,%.0f->%.0f,%.0f  hit=%s",
		ax1,
		ay1,
		ax2,
		ay2,
		tostring(box_a.tui_mouse_input:IsHit(x, y))
	)
	info_b = string.format(
		"%.0f,%.0f->%.0f,%.0f  hit=%s",
		bx1,
		by1,
		bx2,
		by2,
		tostring(box_b.tui_mouse_input:IsHit(x, y))
	)
	needs_redraw = true
end)

-- ── Ctrl+C to quit ─────────────────────────────────────────────────────────
local function teardown()
	event.RemoveListener("TerminalKeyInput", "tui_mouse_debug_key")
	event.RemoveListener("TerminalMouseMoved", "tui_mouse_debug")
	event.RemoveListener("Update", "tui_mouse_debug_draw")
	TuiPanel.World:RemoveChildren()
end

event.AddListener(
	"TerminalKeyInput",
	"tui_mouse_debug_key",
	function(key, press, mods)
		if key == "c" and mods and mods.ctrl and press then
			repl.SetEnabled(true)
			teardown()
		end
	end,
	{priority = 100}
)

-- ── draw loop ──────────────────────────────────────────────────────────────
event.AddListener(
	"Update",
	"tui_mouse_debug_draw",
	function()
		if repl.GetEnabled() then return end

		if not needs_redraw then return end

		needs_redraw = false
		local term = repl.GetTerminal()

		if not term then return end

		term:BeginFrame()
		term:Clear()
		TuiPanel.Draw(term)
		local draw_row = 1

		local function writeln(s)
			term:SetCaretPosition(1, draw_row)
			term:Write(s)
			draw_row = draw_row + 1
		end

		writeln(string.format("mouse  : %d, %d", mouse_x, mouse_y))
		writeln("box_a  : " .. info_a)
		writeln("box_b  : " .. info_b)
		writeln(
			"─────────────────────────────"
		)
		writeln("events (newest last):")

		for _, l in ipairs(lines) do
			writeln("  " .. l)
		end

		term:EndFrame()
		term:Flush()
	end,
	{priority = -200}
)

repl.SetEnabled(false)