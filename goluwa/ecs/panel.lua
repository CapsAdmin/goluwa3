local valid = nil
local Panel = import("goluwa/ecs/base.lua")("panel", "ecs.components.2d.", function()
	valid = valid or
		{
			animation = import("goluwa/ecs/components/2d/animation.lua"),
			clickable = import("goluwa/ecs/components/2d/clickable.lua"),
			ui_debug = import("goluwa/ecs/components/2d/ui_debug.lua"),
			gui_element = import("goluwa/ecs/components/2d/gui_element.lua"),
			key_input = import("goluwa/ecs/components/2d/key_input.lua"),
			layout = import("goluwa/ecs/components/2d/layout.lua"),
			mouse_input = import("goluwa/ecs/components/2d/mouse_input.lua"),
			rect = import("goluwa/ecs/components/2d/rect.lua"),
			resizable = import("goluwa/ecs/components/2d/resizable.lua"),
			style = import("goluwa/ecs/components/2d/style.lua"),
			text = import("goluwa/ecs/components/2d/text.lua"),
			transform = import("goluwa/ecs/components/2d/transform.lua"),
			draggable = import("goluwa/ecs/components/2d/draggable.lua"),
		}
	return valid
end)
import.loaded["goluwa/ecs/panel.lua"] = Panel

do
	local base_new = Panel.New

	local function find_tooltip_props(config, state)
		if type(config) ~= "table" then return end

		if config.Tooltip ~= nil then
			state.source = config.Tooltip
			config.Tooltip = nil
		end

		if config.TooltipOptions ~= nil then
			state.options = table.shallow_copy(config.TooltipOptions)
			config.TooltipOptions = nil
		end

		if config.TooltipMaxWidth ~= nil then
			state.options = state.options or {}
			state.options.MaxWidth = config.TooltipMaxWidth
			config.TooltipMaxWidth = nil
		end

		if config.TooltipOffset ~= nil then
			state.options = state.options or {}
			state.options.Offset = config.TooltipOffset
			config.TooltipOffset = nil
		end

		for i = 1, #config do
			find_tooltip_props(config[i], state)
		end
	end

	function Panel.New(config)
		local tooltip_state = {}
		find_tooltip_props(config, tooltip_state)
		local ent = base_new(config)

		if tooltip_state.source ~= nil then
			import("lua/ui/tooltip.lua").Attach(ent, tooltip_state.source, tooltip_state.options)
		end

		return ent
	end
end

Panel.World = Panel.New{
	ComponentSet = {
		"transform",
		"ui_debug",
		"gui_element",
	},
}

do
	local system = import("goluwa/system.lua")
	local Vec2 = import("goluwa/structs/vec2.lua")
	Panel.World:SetName("WorldPanel")
	local window = system.GetWindow()
	Panel.World.transform:SetSize(Vec2(window and window:GetSize() or Vec2()))
	Panel.World:AddGlobalEvent("WindowFramebufferResized")

	function Panel.World:OnWindowFramebufferResized(window, size)
		self.transform:SetSize(size)
	end
end

return Panel
