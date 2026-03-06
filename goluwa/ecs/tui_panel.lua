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

return TuiPanel