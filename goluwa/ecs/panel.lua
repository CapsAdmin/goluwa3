local valid = nil
local Panel = import("goluwa/ecs/base.lua")("panel", "ecs.components.2d.", function()
	valid = valid or
		{
			animation = import("goluwa/ecs/components/2d/animation.lua"),
			clickable = import("goluwa/ecs/components/2d/clickable.lua"),
			gui_element = import("goluwa/ecs/components/2d/gui_element.lua"),
			key_input = import("goluwa/ecs/components/2d/key_input.lua"),
			layout = import("goluwa/ecs/components/2d/layout.lua"),
			mouse_input = import("goluwa/ecs/components/2d/mouse_input.lua"),
			rect = import("goluwa/ecs/components/2d/rect.lua"),
			resizable = import("goluwa/ecs/components/2d/resizable.lua"),
			text = import("goluwa/ecs/components/2d/text.lua"),
			transform = import("goluwa/ecs/components/2d/transform.lua"),
			draggable = import("goluwa/ecs/components/2d/draggable.lua"),
		}
	return valid
end)
import.loaded["goluwa/ecs/panel.lua"] = Panel
Panel.World = Panel.New{
	ComponentSet = {
		"transform",
		"gui_element",
	},
}

do
	local window = import("goluwa/window.lua")
	local Vec2 = import("goluwa/structs/vec2.lua")
	Panel.World:SetName("WorldPanel")
	Panel.World.transform:SetSize(Vec2(window.GetSize()))
	Panel.World:AddGlobalEvent("WindowFramebufferResized")

	function Panel.World:OnWindowFramebufferResized(window, size)
		self.transform:SetSize(size)
	end
end

return Panel