local render2d = import("goluwa/render2d/render2d.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Color = import("goluwa/structs/color.lua")
local Rect = import("goluwa/structs/rect.lua")
local Ang3 = import("goluwa/structs/ang3.lua")
local prototype = import("goluwa/prototype.lua")
local fonts = import("goluwa/render2d/fonts.lua")
local gfx = import("goluwa/render2d/gfx.lua")
local Panel = import("goluwa/ecs/panel.lua")
local theme = import("lua/ui/theme.lua")
return function(props)
	return Panel.New{
		props,
		{
			Name = "frame",
			OnSetProperty = theme.OnSetProperty,
			gui_element = {
				OnDraw = function(self)
					theme.active:DrawFrame(theme.GetDrawContext(self, true), props.Emphasis or 1, "surface")
				end,
				OnPostDraw = function(self)
					theme.active:DrawFramePost(theme.GetDrawContext(self, true), props.Emphasis or 1, "surface")
				end,
			},
			layout = {
				Padding = props.Padding,
				props.layout,
			},
			transform = true,
			mouse_input = {
				Cursor = props.OnClick and "pointer" or "arrow",
			},
			clickable = true,
			OnClick = props.OnClick,
			animation = true,
		},
	}
end
