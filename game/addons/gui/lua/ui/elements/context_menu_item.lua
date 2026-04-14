local Rect = import("goluwa/structs/rect.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Color = import("goluwa/structs/color.lua")
local Clickable = import("lua/ui/elements/clickable.lua")
local Text = import("lua/ui/elements/text.lua")
local theme = import("lua/ui/theme.lua")
return function(props)
	local item

	local function close_context_menu()
		local current = item

		while current and current.IsValid and current:IsValid() do
			if current:GetName() == "ContextMenuContainer" then
				current:Remove()
				return
			end

			current = current:GetParent()
		end
	end

	item = Clickable{
		Size = props.Size or "M",
		Active = props.Active,
		Disabled = props.Disabled,
		OnClick = function(...)
			close_context_menu()

			if props.OnClick then
				return props.OnClick(...)
			end
		end,
		layout = {
			Direction = "x",
			AlignmentY = "center",
			FitHeight = true,
			GrowWidth = 1,
		},
		Padding = "M",
	}{
		Text{
			layout = {
				GrowWidth = 1,
				FitHeight = true,
			},
			Text = props.Text,
			IgnoreMouseInput = true,
			Color = props.Disabled and "text_disabled" or "text_foreground",
		},
	}

	return item
end
