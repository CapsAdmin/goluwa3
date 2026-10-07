local Vec2 = import("goluwa/structs/vec2.lua")
local event = import("goluwa/event.lua")
local IconButton = import("goluwa/render2d/ui/widgets/icon_button.lua")
local Value = import("goluwa/render2d/ui/widgets/properties/value.lua")
return function(props)
	local node = props.node
	local control
	local default_encoded
	control = Value{
		Value = node.Value == nil and "" or tostring(node.Value),
		Tooltip = function()
			return node.Value == nil and "" or tostring(node.Value)
		end,
		TooltipMaxWidth = 360,
		FontSize = props.font_size,
		Padding = props.padding,
		Size = Vec2(props.value_width, props.row_height),
		MinSize = Vec2(props.value_width, props.row_height),
		MaxSize = Vec2(props.value_width, props.row_height),
		RightElements = {
			IconButton{
				Text = "...",
				IconSize = "M",
				FontSize = "M",
				Padding = "none",
				Mode = "outline",
				OnClick = function()
					event.Call(
						"PickObject",
						"asset",
						function(path)
							control:SetValue(path, true)
						end,
						{category = node.AssetCategory, path = control:GetValue()}
					)

					return true
				end,
			},
		},
		OnChange = function(value)
			props.commit_value(node, value, props.key, props.path)
		end,
		ContextMenu = {
			BeforeOpen = function()
				if props.sync_selection then props.sync_selection(props.key) end
			end,
			Encode = function(panel)
				return panel:EncodeValue()
			end,
			Decode = function(text, panel)
				return panel:DecodeValue(text)
			end,
			GetDefaultEncoded = function()
				return default_encoded
			end,
			Commit = function(decoded, panel)
				props.commit_value(node, decoded, props.key, props.path, panel)
			end,
		},
		layout = {FitWidth = false},
	}

	if node.DefaultEncoded ~= nil then
		default_encoded = tostring(node.DefaultEncoded)
	elseif node.Default ~= nil then
		default_encoded = tostring(node.Default)
	else
		default_encoded = control:EncodeValue()
	end

	return control, control
end
