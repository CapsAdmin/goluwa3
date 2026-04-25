local Vec2 = import("goluwa/structs/vec2.lua")
local Dropdown = import("lua/ui/elements/dropdown.lua")

return function(props)
	local node = props.node
	local control = Dropdown{
		Text = props.get_option_text(node.Options, node.Value),
		FontSize = props.font_size,
		Options = node.Options or {},
		GetText = function()
			return props.get_option_text(node.Options, node.Value)
		end,
		OnSelect = function(value)
			props.commit_value(node, value, props.key, props.path)
		end,
		Padding = node.Padding or props.padding,
		layout = {
			MinSize = Vec2(props.value_width, props.row_height),
			MaxSize = Vec2(props.value_width, props.row_height),
		},
	}
	return control, control
end