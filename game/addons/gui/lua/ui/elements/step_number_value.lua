local Vec2 = import("goluwa/structs/vec2.lua")
local Button = import("lua/ui/elements/button.lua")
local Column = import("lua/ui/elements/column.lua")
local NumberValue = import("lua/ui/elements/number_value.lua")
local Row = import("lua/ui/elements/row.lua")

local function get_default_step(props)
	if props.Step ~= nil then return props.Step end

	local precision = tonumber(props.Precision) or 0

	if precision > 0 then return 10 ^ -precision end

	return 1
end

return function(props)
	props = props or {}
	local external_ref = props.Ref

	if external_ref then
		props = table.shallow_copy(props)
		props.Ref = nil
	end

	local size = props.Size or Vec2(92, 34)
	local min_size = props.MinSize or Vec2(92, size.y)
	local max_size = props.MaxSize or Vec2(0, size.y)
	local button_gap = props.ButtonGap or 1
	local button_width = props.ButtonWidth or math.max(16, math.floor(size.y * 0.42))
	local button_height = math.max(8, math.floor((size.y - button_gap) / 2))
	local field_width = math.max(24, size.x - button_width - 4)
	local input
	local control

	local function adjust_value(direction)
		if not input or not input:IsValid() then return end

		local next_value = (tonumber(input:GetValue()) or 0) + direction * get_default_step(props)
		input:SetValue(next_value, true)
	end

	control = Row{
		Name = props.Name or "step_number_value",
		transform = {
			Size = size,
		},
		layout = {
			GrowWidth = 1,
			FitWidth = false,
			MinSize = min_size,
			MaxSize = max_size,
			ChildGap = 4,
			AlignmentY = "center",
			props.layout,
		},
	}{
		NumberValue{
			Ref = function(self)
				input = self
			end,
			Value = props.Value,
			Min = props.Min,
			Max = props.Max,
			Precision = props.Precision,
			DragStep = props.DragStep,
			Padding = props.Padding,
			BorderRadius = props.BorderRadius,
			HoverPanelColor = props.HoverPanelColor,
			EditPanelColor = props.EditPanelColor,
			TextColor = props.TextColor,
			Font = props.Font,
			FontName = props.FontName,
			FontSize = props.FontSize,
			Cursor = props.Cursor,
			Size = Vec2(field_width, size.y),
			MinSize = Vec2(field_width, size.y),
			MaxSize = Vec2(field_width, size.y),
			OnChange = function(value, old_value)
				if props.OnChange then props.OnChange(value, old_value) end
			end,
			layout = {
				GrowWidth = 1,
				FitWidth = false,
			},
		},
		Column{
			layout = {
				GrowWidth = 0,
				FitWidth = false,
				ChildGap = button_gap,
				MinSize = Vec2(button_width, size.y),
				MaxSize = Vec2(button_width, size.y),
			},
		}{
			Button{
				Text = "^",
				FontSize = props.ButtonFontSize or "XXS",
				Padding = "none",
				OnClick = function()
					adjust_value(1)
				end,
				layout = {
					GrowWidth = 0,
					FitWidth = false,
					MinSize = Vec2(button_width, button_height),
					MaxSize = Vec2(button_width, button_height),
				},
			},
			Button{
				Text = "v",
				FontSize = props.ButtonFontSize or "XXS",
				Padding = "none",
				OnClick = function()
					adjust_value(-1)
				end,
				layout = {
					GrowWidth = 0,
					FitWidth = false,
					MinSize = Vec2(button_width, button_height),
					MaxSize = Vec2(button_width, button_height),
				},
			},
		},
	}

	function control:SetValue(value, notify)
		if input and input:IsValid() then input:SetValue(value, notify) end

		return self
	end

	function control:GetValue()
		if input and input:IsValid() then return input:GetValue() end

		return tonumber(props.Value) or 0
	end

	function control:GetMin()
		if input and input:IsValid() and input.GetMin then return input:GetMin() end
	end

	function control:SetMin(value)
		if input and input:IsValid() and input.SetMin then input:SetMin(value) end

		return self
	end

	function control:GetMax()
		if input and input:IsValid() and input.GetMax then return input:GetMax() end
	end

	function control:SetMax(value)
		if input and input:IsValid() and input.SetMax then input:SetMax(value) end

		return self
	end

	function control:EncodeValue()
		if input and input:IsValid() and input.EncodeValue then
			return input:EncodeValue()
		end

		return tostring(self:GetValue())
	end

	function control:DecodeValue(text)
		if input and input:IsValid() and input.DecodeValue then
			return input:DecodeValue(text)
		end

		local numeric = tonumber(text)

		if numeric == nil then return nil, false end

		return numeric, true
	end

	if external_ref then external_ref(control) end

	return control
end
