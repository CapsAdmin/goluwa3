local Vec2 = import("goluwa/structs/vec2.lua")
local Clickable = import("lua/ui/elements/clickable.lua")
local SVG = import("lua/ui/elements/svg.lua")
local Text = import("lua/ui/elements/text.lua")
return function(props)
	local item
	local children = {}

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

	if props.IconSource then
		children[#children + 1] = SVG{
			Source = props.IconSource,
			Size = Vec2(16, 16),
			MinSize = Vec2(16, 16),
			MaxSize = Vec2(16, 16),
			Color = props.Disabled and "text_disabled" or "text_foreground",
			IgnoreMouseInput = true,
			layout = {
				GrowWidth = 0,
				FitWidth = false,
			},
		}
	end

	children[#children + 1] = Text{
		layout = {
			GrowWidth = 1,
			FitHeight = true,
		},
		Text = props.Text,
		IgnoreMouseInput = true,
		Color = props.Disabled and "text_disabled" or "text_foreground",
	}
	item = Clickable{
		Size = props.Size or "M",
		Active = props.Active,
		Disabled = props.Disabled,
		OnClick = function(...)
			close_context_menu()

			if props.OnClick then return props.OnClick(...) end
		end,
		layout = {
			Direction = "x",
			AlignmentY = "center",
			FitHeight = true,
			GrowWidth = 1,
		},
		Padding = "M",
	}(children)
	return item
end
