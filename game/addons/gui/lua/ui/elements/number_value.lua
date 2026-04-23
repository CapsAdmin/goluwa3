local Value = import("lua/ui/elements/value.lua")
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

return function(props)
	props = props or {}
	local min = props.Min ~= nil and props.Min or -math.huge
	local max = props.Max ~= nil and props.Max or math.huge
	local precision = props.Precision
	local drag_precision_boost = props.DragPrecisionBoost or 2
	local control

	if precision == nil then precision = 2 end

	local function get_display_precision()
		if control and control.IsDragging and control:IsDragging() then
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

	control = Value{
		Name = props.Name or "number_value",
		Ref = props.Ref,
		Value = tonumber(props.Value) or 0,
		Size = props.Size,
		MinSize = props.MinSize,
		MaxSize = props.MaxSize,
		Padding = props.Padding,
		BorderRadius = props.BorderRadius,
		HoverPanelColor = props.HoverPanelColor,
		EditPanelColor = props.EditPanelColor,
		TextColor = props.TextColor,
		Font = props.Font,
		FontName = props.FontName,
		FontSize = props.FontSize,
		Cursor = props.Cursor or "vertical_resize",
		layout = props.layout,
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
	}
	local base_set_value = control.SetValue

	function control:SetValue(value, notify)
		local numeric = tonumber(value)

		if numeric == nil then numeric = 0 end

		return base_set_value(self, clamp_number(numeric, min, max), notify)
	end

	function control:GetMin()
		return min
	end

	function control:SetMin(value)
		min = value or -math.huge
		self:SetValue(self:GetValue())
		return self
	end

	function control:GetMax()
		return max
	end

	function control:SetMax(value)
		max = value or math.huge
		self:SetValue(self:GetValue())
		return self
	end

	function control:EncodeValue()
		return format_number(self:GetValue(), precision)
	end

	function control:DecodeValue(text)
		local numeric = tonumber(text)

		if numeric == nil then return nil, false end

		return clamp_number(numeric, min, max), true
	end

	control:SetValue(props.Value)
	return control
end
