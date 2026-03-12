local render2d = import("goluwa/render2d/render2d.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Color = import("goluwa/structs/color.lua")
local Ang3 = import("goluwa/structs/ang3.lua")
local window = import("goluwa/window.lua")
local Panel = import("goluwa/ecs/panel.lua")
local Texture = import("goluwa/render/texture.lua")
local theme = import("lua/ui/theme.lua")
return function(props)
	props = props or {}
	return Panel.New{
		Name = "MenuSpacer",
		OnSetProperty = theme.OnSetProperty,
		transform = {
			Size = props.Vertical and
				Vec2(theme.GetSize("line_height"), 0) or
				Vec2(0, theme.GetSize("line_height")),
		},
		layout = {
			GrowWidth = 1,
		},
		gui_element = {
			OnDraw = function(self)
				theme.panels.menu_spacer(self, props.Vertical)
			end,
		},
		mouse_input = true,
		clickable = true,
		animation = true,
	}
end