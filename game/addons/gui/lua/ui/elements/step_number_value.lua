local Vec2 = import("goluwa/structs/vec2.lua")
local Button = import("lua/ui/elements/button.lua")
local Column = import("lua/ui/elements/column.lua")
local Row = import("lua/ui/elements/row.lua")
local Value = import("lua/ui/elements/properties/value.lua")
local input = import("goluwa/input.lua")

local function is_finite(value)
	return value ~= math.huge and value ~= -math.huge
end

local function clamp_number(value, min, max)
	return math.clamp(value, min, max)
end

local function format_number(value, precision)
	local numeric = tonumber(value)

	if numeric == nil then return "" end

	if precision == nil then return tostring(numeric) end

	if precision <= 0 then return tostring(math.round(numeric)) end

	local formatted = string.format("%." .. precision .. "f", numeric)
	formatted = formatted:gsub("(%..-)0+$", "%1")
	formatted = formatted:gsub("%.$", "")
	return formatted
end

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
	local min = props.Min ~= nil and props.Min or -math.huge
	local max = props.Max ~= nil and props.Max or math.huge
	local precision = props.Precision
	local drag_precision_boost = props.DragPrecisionBoost or 2
	local input
	local control

	if precision == nil then precision = 2 end

	local function get_display_precision()
		if input and input.IsDragging and input:IsDragging() then
			if input.IsKeyDown("left_alt") or input.IsKeyDown("right_alt") then
				return precision + drag_precision_boost
			end
		end

		return precision
	end

	local function get_drag_step()
		if props.DragStep ~= nil then return props.DragStep end

		if is_finite(min) and is_finite(max) then
			return math.max((max - min) / 100, precision > 0 and 10 ^ -precision or 1)
		end

		if precision > 0 then return 10 ^ -precision end

		return 1
	end

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
		Value{
			Ref = function(self)
				input = self
			end,
			Value = props.Value,
			Padding = props.Padding,
			BorderRadius = props.BorderRadius,
			HoverPanelColor = props.HoverPanelColor,
			EditPanelColor = props.EditPanelColor,
			TextColor = props.TextColor,
			Font = props.Font,
			FontName = props.FontName,
			FontSize = props.FontSize,
			Cursor = props.Cursor or "vertical_resize",
			Size = Vec2(field_width, size.y),
			MinSize = Vec2(field_width, size.y),
			MaxSize = Vec2(field_width, size.y),
			EditClickCount = 2,
			FormatValue = function(value)
				return format_number(value, get_display_precision())
			end,
			FormatEditValue = function(value)
				return format_number(value, get_display_precision())
			end,
			ParseValue = function(text, current_value)
				local numeric = tonumber(text)

				if numeric == nil then return current_value end

				return clamp_number(numeric, min, max)
			end,
			OnDragValue = function(delta, start_value)
				local step = get_drag_step()
				local rounding_precision = precision

				if input.IsKeyDown("left_alt") or input.IsKeyDown("right_alt") then
					step = step * 0.1
					rounding_precision = precision + drag_precision_boost
				end

				local next_value = (tonumber(start_value) or 0) - delta.y * step

				if input.IsKeyDown("left_control") or input.IsKeyDown("right_control") then
					next_value = math.round(next_value)
				elseif rounding_precision >= 0 then
					next_value = math.round(next_value, rounding_precision)
				end

				return clamp_number(next_value, min, max)
			end,
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
	local base_set_value = input.SetValue

	function input:SetValue(value, notify)
		local numeric = tonumber(value)

		if numeric == nil then numeric = 0 end

		return base_set_value(self, clamp_number(numeric, min, max), notify)
	end

	function input:GetMin()
		return min
	end

	function input:SetMin(value)
		min = value or -math.huge
		self:SetValue(self:GetValue())
		return self
	end

	function input:GetMax()
		return max
	end

	function input:SetMax(value)
		max = value or math.huge
		self:SetValue(self:GetValue())
		return self
	end

	function input:EncodeValue()
		return format_number(self:GetValue(), precision)
	end

	function input:DecodeValue(text)
		local numeric = tonumber(text)

		if numeric == nil then return nil, false end

		return clamp_number(numeric, min, max), true
	end

	input:SetValue(props.Value)

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
