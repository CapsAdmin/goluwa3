local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Rect = import("goluwa/structs/rect.lua")
local Color = import("goluwa/structs/color.lua")
local Ang3 = import("goluwa/structs/ang3.lua")
local fonts = import("goluwa/render2d/fonts.lua")
local Panel = import("goluwa/ecs/panel.lua")
local theme = import("lua/ui/theme.lua")
return function(props)
	props = props or {}

	local function get_context_text_color()
		local value = props.TextColor

		if value ~= nil then return value end

		if props.Disabled then
			return "text_disabled"
		elseif props.Active then
			return "accent"
		end

		return "text"
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
				Color = props.Color ~= nil and props.Color or get_context_text_color(),
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
