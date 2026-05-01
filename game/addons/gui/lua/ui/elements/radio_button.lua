local Vec2 = import("goluwa/structs/vec2.lua")
local Color = import("goluwa/structs/color.lua")
local Rect = import("goluwa/structs/rect.lua")
local Panel = import("goluwa/ecs/panel.lua")
local theme = import("lua/ui/theme.lua")
return function(props)
	local panel
	panel = Panel.New{
		{
			Name = "radio_button",
			transform = {
				Size = props.Size or "M",
			},
			layout = {
				props.layout,
			},
			OnClick = function(self)
				local selected = props.IsSelected and props.IsSelected() or self:GetState("value")

				if not selected then
					if props.OnSelect then props.OnSelect() end

					self:SetState("value", true)
				end
			end,
			mouse_input = {
				Cursor = "hand",
				OnHover = function(self, hovered)
					panel:SetState("hovered", hovered)
				end,
			},
			gui_element = {
				OnDraw = function(self)
					if not props.IsSelected() then panel:SetState("value", false) end

					theme.active:Draw(panel)
				end,
			},
			animation = true,
			clickable = true,
		},
	}
	panel:SetState("value", false)
	panel:SetState("hovered", false)
	return panel
end
