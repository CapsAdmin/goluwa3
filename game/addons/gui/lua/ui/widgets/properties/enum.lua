local Vec2 = import("goluwa/structs/vec2.lua")
local Dropdown = import("lua/ui/widgets/dropdown.lua")
local Value = import("lua/ui/widgets/properties/value.lua")
return function(props)
	local node = props.node
	local default_encoded

	local function decode_enum(text)
		local normalized = tostring(text or ""):match("^%s*(.-)%s*$")
		local normalized_lower = normalized:lower()

		for _, option in ipairs(node.Options or {}) do
			local option_text
			local option_value

			if type(option) == "table" then
				option_text = tostring(option.Text or option.Label or option.Value)
				option_value = option.Value
			else
				option_text = tostring(option)
				option_value = option
			end

			if tostring(option_value) == normalized or option_text:lower() == normalized_lower then
				return option_value, true
			end
		end

		return nil, false
	end

	local function get_option_text(options, value)
		for _, option in ipairs(options or {}) do
			if type(option) == "table" then
				if option.Value == value then
					return tostring(option.Text or option.Label or option.Value)
				end
			elseif option == value then
				return tostring(option)
			end
		end

		if value == nil then return "Select..." end

		return tostring(value)
	end

	local control = Dropdown{
		Text = get_option_text(node.Options, node.Value),
		FontSize = props.font_size,
		Options = node.Options or {},
		Searchable = node.Searchable ~= false,
		GetText = function()
			return get_option_text(node.Options, node.Value)
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

	function control:EncodeValue()
		return tostring(node.Value)
	end

	function control:DecodeValue(text)
		return decode_enum(text)
	end

	if node.DefaultEncoded ~= nil then
		default_encoded = tostring(node.DefaultEncoded)
	elseif node.Default ~= nil then
		default_encoded = tostring(node.Default)
	else
		default_encoded = control:EncodeValue()
	end

	Value.InstallContextMenu(
		control,
		{
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
			Commit = function(decoded)
				props.commit_value(node, decoded, props.key, props.path)
			end,
		}
	)
	return control, control
end
