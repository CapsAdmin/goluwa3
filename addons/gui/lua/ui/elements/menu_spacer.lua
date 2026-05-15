local Vec2 = import("goluwa/structs/vec2.lua")
local Panel = import("goluwa/ecs/panel.lua")
local theme = import("lua/ui/theme.lua")
return function(props)
	props = props or {}
	local is_vertical = props.Vertical == true
	local spacer_extent = theme.GetSize(props.Size or "XS")
	local panel = Panel.New{
		Name = "MenuSpacer",
		transform = {
			Size = is_vertical and Vec2(spacer_extent, 0) or Vec2(0, spacer_extent),
		},
		layout = {
			GrowWidth = is_vertical and 0 or 1,
			GrowHeight = is_vertical and 1 or 0,
			FitWidth = false,
			FitHeight = false,
		},
		gui_element = {
			OnDraw = function(self)
				theme.active:Draw(self.Owner)
			end,
		},
		mouse_input = {
			IgnoreMouseInput = true,
		},
	}
	panel:SetState("vertical", is_vertical)
	return panel
end
