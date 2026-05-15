local Vec2 = import("goluwa/structs/vec2.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local Panel = import("goluwa/ecs/panel.lua")
local Row = import("lua/ui/elements/row.lua")
local Text = import("lua/ui/elements/text.lua")
local theme = import("lua/ui/theme.lua")

local function set_text(panel, value)
	if panel and panel:IsValid() and panel.text then
		panel.text:SetText(value or "")
	end
end

return function(props)
	local node = props.node
	local label
	local control
	local action_button_size = node.ActionButtonSize or props.row_height
	local action_padding = node.ActionPreviewPadding or 4

	local function get_display_text(value)
		if node.GetDisplayText then return node.GetDisplayText(value) end

		return value == nil and "None" or tostring(value)
	end

	local function get_action_texture(value)
		if node.GetActionTexture then return node.GetActionTexture(value) end

		if node.GetPreviewTexture then return node.GetPreviewTexture(value) end

		return nil
	end

	local function refresh_display(value)
		set_text(label, get_display_text(value))
	end

	local function draw_action_button(self)
		local size = self.Owner.transform:GetSize()
		local texture = get_action_texture(node.Value)
		theme.active:Draw(self.Owner)

		if node.OnDrawActionButton then
			node.OnDrawActionButton(node, self.Owner, size, node.Value, props.key, props.path)
			return
		end

		if texture then
			render2d.SetTexture(texture)
			render2d.SetColor(1, 1, 1, 1)
			render2d.DrawRect(
				action_padding,
				action_padding,
				size.x - action_padding * 2,
				size.y - action_padding * 2
			)
		end
	end

	control = Row{
		layout = {
			FitWidth = false,
			MinSize = Vec2(props.value_width, props.row_height),
			MaxSize = Vec2(props.value_width, props.row_height),
			AlignmentY = "center",
			ChildGap = props.gap,
		},
	}{
		Panel.New{
			Name = "PropertyObjectValue",
			transform = {
				Size = Vec2(props.value_width - action_button_size - 4, props.row_height),
			},
			layout = {
				FitWidth = false,
				GrowWidth = 1,
				MinSize = Vec2(props.value_width - action_button_size - 4, props.row_height),
				MaxSize = Vec2(props.value_width - action_button_size - 4, props.row_height),
				Padding = props.padding,
				AlignmentY = "center",
			},
			gui_element = {
				OnDraw = function(self)
					theme.active:Draw(self.Owner)
				end,
			},
			mouse_input = {
				IgnoreMouseInput = true,
			},
		}{
			Text{
				Ref = function(self)
					label = self
					refresh_display(node.Value)
				end,
				Text = get_display_text(node.Value),
				FontSize = props.font_size,
				Elide = true,
				ElideString = "...",
				IgnoreMouseInput = true,
				layout = {
					GrowWidth = 1,
					FitWidth = false,
					FitHeight = true,
				},
			},
		},
		Panel.New{
			Name = "PropertyObjectActionButton",
			transform = {
				Size = Vec2(action_button_size, action_button_size),
			},
			layout = {
				FitWidth = false,
				MinSize = Vec2(action_button_size, action_button_size),
				MaxSize = Vec2(action_button_size, action_button_size),
			},
			gui_element = {
				OnDraw = draw_action_button,
			},
			mouse_input = {
				Cursor = "pointer",
			},
			clickable = true,
			OnClick = function()
				if node.OnActionButton then
					node.OnActionButton(node, props.key, props.path, control, props.commit_value)
				elseif node.OnBrowse then
					node.OnBrowse(node, props.key, props.path, control, props.commit_value)
				end

				return true
			end,
		},
	}

	function control:SetValue(value)
		node.Value = value
		refresh_display(value)
		return self
	end

	function control:EncodeValue()
		return nil
	end

	function control:DecodeValue()
		return nil, false
	end

	control:SetValue(node.Value)
	return control, control
end
