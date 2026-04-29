local render2d = import("goluwa/render2d/render2d.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Rect = import("goluwa/structs/rect.lua")
local Color = import("goluwa/structs/color.lua")
local Ang3 = import("goluwa/structs/ang3.lua")
local fonts = import("goluwa/render2d/fonts.lua")
local Panel = import("goluwa/ecs/panel.lua")
local theme = import("lua/ui/theme.lua")
return function(props)
	return Panel.New{
		{
			Name = "text",
			OnSetProperty = theme.OnSetProperty,
			OnGetTextColor = function()
				if props.Disabled then
					return theme.GetColor("text_disabled", theme.active.surface_color)
				elseif props.Active then
					return theme.GetColor("accent", theme.active.surface_color)
				else
					return theme.GetColor("text", theme.active.surface_color)
				end
			end,
			text = {
				Elide = props.Elide == true,
				ElideString = props.ElideString or "...",
				Font = props.Font or props.FontName or "body",
				FontSize = props.FontSize or "M",
				WrapToParent = props.Wrap and props.WrapToParent ~= false,
				Color = "text",
			},
			layout = {
				FitWidth = not props.Wrap and props.Elide ~= true,
				FitHeight = true,
			},
			transform = true,
			gui_element = true,
			mouse_input = {
				Cursor = props.Cursor,
			},
			animation = true,
		},
		props,
	}
end
