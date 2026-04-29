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

	local function get_owner(self)
		if self and self.Owner then return self.Owner end

		return self
	end

	local function get_context_surface(self)
		local current = get_owner(self)

		while current and current.IsValid and current:IsValid() do
			if current.SurfaceColor ~= nil then return current.SurfaceColor end

			current = current:GetParent()
		end

		return theme.GetCurrentSurface()
	end

	local function get_context_text_color(self)
		local owner = get_owner(self)
		local value = owner and owner.TextColor

		if value == nil and owner then value = owner.Color end

		if value == nil then
			if owner and owner.Disabled then
				value = "text_disabled"
			elseif owner and owner.Active then
				value = "accent"
			else
				value = "text"
			end
		end

		if type(value) == "string" then
			return theme.GetColorOn(value, get_context_surface(self))
		end

		return value
	end

	return Panel.New{
		{
			Name = "text",
			OnSetProperty = theme.OnSetProperty,
			OnGetTextColor = get_context_text_color,
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
