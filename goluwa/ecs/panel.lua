local Panel = require("ecs.base")("panel", "ecs.components.2d.", function()
	return {
		animation = require("ecs.components.2d.animation"),
		clickable = require("ecs.components.2d.clickable"),
		gui_element = require("ecs.components.2d.gui_element"),
		key_input = require("ecs.components.2d.key_input"),
		layout = require("ecs.components.2d.layout"),
		mouse_input = require("ecs.components.2d.mouse_input"),
		rect = require("ecs.components.2d.rect"),
		resizable = require("ecs.components.2d.resizable"),
		text = require("ecs.components.2d.text"),
		transform = require("ecs.components.2d.transform"),
	}
end)
package.loaded["ecs.panel"] = Panel
Panel.World = Panel.New({
	ComponentSet = {
		"transform",
		"gui_element",
		"layout",
	},
})

do
	local window = require("window")
	local Vec2 = require("structs.vec2")
	Panel.World:SetName("WorldPanel")
	Panel.World.transform:SetSize(Vec2(window.GetSize()))
	Panel.World:AddEvent("WindowFramebufferResized")

	function Panel.World:OnWindowFramebufferResized(window, size)
		self.transform:SetSize(size)
	end
end

return Panel
