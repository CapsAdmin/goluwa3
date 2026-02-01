local Rect = require("structs.rect")
local Color = require("structs.color")
local Button = runfile("lua/ui/elements/button.lua")
local Text = runfile("lua/ui/elements/text.lua")

return function(props)
	local is_disabled = #props == 0 and not props.OnClick

	local children = {
		Text(
			{
				Text = props.Text,
				IgnoreMouseInput = true,
				Color = Color(1, 1, 1, 0.8),
				Layout = {"MoveLeft", "CenterY"},
			}
		),
	}

	for i = 1, #props do
		table.insert(children, props[i])
	end

	return Button(
		{
			Stackable = true,
			Padding = Rect(10, 10, 10, 10),
			Active = props.Active,
			Disabled = is_disabled,
			OnClick = props.OnClick,
			unpack(children)
		}
	)
end
