local Vec2 = import("goluwa/structs/vec2.lua")
local Panel = import("goluwa/ecs/panel.lua")
local Text = import("lua/ui/elements/text.lua")
local Value = import("lua/ui/elements/properties/value.lua")
local theme = import("lua/ui/theme.lua")

local function set_text(panel, value)
	if panel and panel:IsValid() and panel.text then
		panel.text:SetText(value or "")
	end
end

return function(props)
	local node = props.node
	local key = props.key
	local path = props.path
	local default_encoded
	local label
	local control
	local checkbox_visual
	local checkbox_state = {
		hovered = false,
		value = node.Value == true,
		anim = {
			glow_alpha = 0,
			check_anim = node.Value == true and 1 or 0,
			last_hovered = false,
			last_value = node.Value == true,
		},
	}

	local function update_boolean_text(value)
		set_text(label, value and "true" or "false")
	end

	local function decode_boolean(text)
		local normalized = tostring(text or ""):match("^%s*(.-)%s*$"):lower()

		if normalized == "true" or normalized == "1" or normalized == "yes" or normalized == "on" then
			return true, true
		end

		if normalized == "false" or normalized == "0" or normalized == "no" or normalized == "off" then
			return false, true
		end

		return nil, false
	end

	control = Panel.New{
		Name = "PropertyBooleanValue",
		OnSetProperty = theme.OnSetProperty,
		transform = {
			Size = Vec2(props.value_width, props.row_height),
		},
		layout = {
			Direction = "x",
			AlignmentY = "center",
			FitWidth = false,
			MinSize = Vec2(props.value_width, props.row_height),
			MaxSize = Vec2(props.value_width, props.row_height),
			Padding = props.padding,
			ChildGap = props.gap,
		},
		gui_element = true,
		mouse_input = {
			Cursor = "hand",
			OnHover = function(self, hovered)
				checkbox_state.hovered = hovered

				if checkbox_visual and checkbox_visual:IsValid() then
					theme.UpdateCheckboxAnimations(checkbox_visual, checkbox_state)
				end
			end,
			OnMouseInput = function(self, button, press)
				if button ~= "button_1" or not press then return end

				local next_value = not control:GetValue()
				control:SetValue(next_value)
				props.commit_value(node, next_value, key, path, control)
				return true
			end,
		},
		clickable = true,
		animation = true,
	}{
		Panel.New{
			Ref = function(self)
				checkbox_visual = self
				theme.UpdateCheckboxAnimations(self, checkbox_state)
			end,
			Name = "PropertyBooleanCheckboxVisual",
			OnSetProperty = theme.OnSetProperty,
			transform = {
				Size = Vec2(theme.GetSize("M"), props.row_height),
			},
			layout = {
				GrowWidth = 0,
				FitWidth = false,
			},
			gui_element = {
				OnDraw = function(self)
					theme.panels.checkbox(self.Owner, checkbox_state)
				end,
			},
			animation = true,
		},
		Text{
			Ref = function(self)
				label = self
				update_boolean_text(node.Value == true)
			end,
			Text = node.Value == true and "true" or "false",
			FontSize = props.font_size,
			IgnoreMouseInput = true,
			layout = {
				GrowWidth = 1,
				FitWidth = false,
				FitHeight = true,
			},
		},
	}

	function control:SetValue(value)
		local boolean = value == true
		checkbox_state.value = boolean

		if checkbox_visual and checkbox_visual:IsValid() then
			theme.UpdateCheckboxAnimations(checkbox_visual, checkbox_state)
		end

		update_boolean_text(boolean)
		return self
	end

	function control:GetValue()
		return checkbox_state.value
	end

	function control:EncodeValue()
		return self:GetValue() and "true" or "false"
	end

	function control:DecodeValue(text)
		return decode_boolean(text)
	end

	control:SetValue(node.Value == true)

	if node.DefaultEncoded ~= nil then
		default_encoded = tostring(node.DefaultEncoded)
	elseif node.Default ~= nil then
		default_encoded = node.Default and "true" or "false"
	else
		default_encoded = control:EncodeValue()
	end

	Value.InstallContextMenu(control, {
		BeforeOpen = function()
			if props.sync_selection then props.sync_selection(key) end
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
			props.commit_value(node, decoded, key, path, panel)
		end,
	})

	return control, control
end