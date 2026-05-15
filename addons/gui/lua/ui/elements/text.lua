local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Rect = import("goluwa/structs/rect.lua")
local Color = import("goluwa/structs/color.lua")
local Ang3 = import("goluwa/structs/ang3.lua")
local fonts = import("goluwa/render2d/fonts.lua")
local Panel = import("goluwa/ecs/panel.lua")
return function(props)
	props = props or {}

	local text_color

	if props.InheritColor then
		text_color = nil
	elseif props.Color ~= nil then
		text_color = props.Color
	else
		text_color = props.TextColor
	end

	return Panel.New{
		{
			Name = "text",
			text = {
				Elide = props.Elide == true,
				ElideString = props.ElideString or "...",
				Font = props.Font or props.FontName or "body",
				FontSize = props.FontSize or "M",
				WrapToParent = props.Wrap and props.WrapToParent ~= false,
				Color = text_color,
			},
			style = {
				BackgroundColor = props.BackgroundColor,
			},
			layout = {
				FitWidth = not props.Wrap and props.Elide ~= true,
				FitHeight = true,
			},
			transform = true,
			mouse_input = {
				Cursor = props.Cursor,
			},
			animation = true,
		},
		props,
	}
end
