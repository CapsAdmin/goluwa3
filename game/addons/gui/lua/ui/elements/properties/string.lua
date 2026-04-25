local Vec2 = import("goluwa/structs/vec2.lua")
local Button = import("lua/ui/elements/button.lua")
local Row = import("lua/ui/elements/row.lua")
local TextEdit = import("lua/ui/elements/text_edit.lua")
local Value = import("lua/ui/elements/properties/value.lua")

return function(props)
	local node = props.node
	local kind = props.kind
	local input
	local multiline = node.Multiline == true
	local input_height = multiline and 72 or props.row_height
	local string_tooltip = function()
		if node.Value == nil then return "" end

		return tostring(node.Value)
	end

	if not multiline then
		local control = Value{
			Value = node.Value == nil and "" or tostring(node.Value),
			Tooltip = kind == "string" and string_tooltip or nil,
			TooltipMaxWidth = 360,
			FontSize = props.font_size,
			Padding = props.padding,
			Size = Vec2(props.value_width, props.row_height),
			MinSize = Vec2(props.value_width, props.row_height),
			MaxSize = Vec2(props.value_width, props.row_height),
			OnChange = function(value)
				props.commit_value(node, value, props.key, props.path)
			end,
			layout = {
				FitWidth = false,
			},
		}
		return control, control
	end

	local control = Row{
		Tooltip = kind == "string" and string_tooltip or nil,
		TooltipMaxWidth = 360,
		layout = {
			FitWidth = true,
			ChildGap = props.gap,
			AlignmentY = "center",
		},
	}{
		TextEdit{
			Ref = function(self)
				input = self
			end,
			Text = node.Value == nil and "" or tostring(node.Value),
			FontSize = props.font_size,
			Size = Vec2(props.value_width, input_height),
			MinSize = Vec2(props.value_width, input_height),
			MaxSize = Vec2(props.value_width, input_height),
			Padding = props.padding,
			Wrap = multiline,
			ScrollY = multiline,
			layout = {
				FitWidth = false,
			},
		},
		Button{
			Text = node.ApplyText or "Apply",
			FontSize = props.font_size,
			Padding = props.padding,
			Mode = "outline",
			OnClick = function()
				if not input or not input:IsValid() then return end

				props.commit_value(node, input:GetText(), props.key, props.path)
			end,
			layout = {
				SelfAlignmentY = multiline and "start" or "center",
			},
		},
	}

	return control,
	{
		EncodeValue = function()
			if input and input:IsValid() then return input:GetText() end

			return tostring(node.Value or "")
		end,
		DecodeValue = function(_, text)
			return tostring(text or ""), true
		end,
		SetValue = function(_, value)
			if input and input:IsValid() then
				input:SetText(value == nil and "" or tostring(value))
			end
		end,
	}
end