local Vec2 = import("goluwa/structs/vec2.lua")
local Value = import("goluwa/render2d/ui/widgets/properties/value.lua")
local input = import("goluwa/input.lua")
local Row = import("goluwa/render2d/ui/elements/row.lua")
local Button = import("goluwa/render2d/ui/widgets/button.lua")
local IconButton = import("goluwa/render2d/ui/widgets/icon_button.lua")
local theme = import("goluwa/render2d/ui/theme.lua")

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
	local node = props.node
	local min = node.Min ~= nil and node.Min or -math.huge
	local max = node.Max ~= nil and node.Max or math.huge
	local number_type = node.NumberType or "float"
	local is_int = number_type == "int"
	local show_stepper = node.ShowStepper == true
	local show_slider = node.ShowSlider == true
	local step = node.Step or (is_int and 1 or 0.01)
	local precision = node.Precision

	if precision == nil then
		if props.get_precision then
			precision = props.get_precision(node, props.number_precision)
		else
			precision = props.number_precision
		end
	end

	if precision == nil then precision = is_int and 0 or 2 end

	local drag_precision_boost = node.DragPrecisionBoost or 2
	local drag_step = node.DragStep
	local control
	local default_encoded

	local function get_display_precision()
		if control and control.IsDragging and control:IsDragging() then
			if input.IsKeyDown("left_alt") or input.IsKeyDown("right_alt") then
				return precision + drag_precision_boost
			end
		end

		return precision
	end

	local function get_drag_step()
		if drag_step ~= nil then return drag_step end

		if is_finite(min) and is_finite(max) then
			return math.max((max - min) / 100, precision > 0 and 10 ^ -precision or 1)
		end

		if precision > 0 then return 10 ^ -precision end

		return 1
	end

	-- Build right elements (stepper buttons)
	local right_elements = {}

	if show_stepper then
		right_elements[#right_elements + 1] = Row{
			layout = {
				ChildGap = 0,
				FitWidth = true,
				GrowWidth = 0,
				AlignmentX = "stretch",
			},
		}{
			IconButton{
				Text = "-",
				IconSize = "M",
				FontSize = "M",
				Padding = "none",
				Mode = "outline",
				OnClick = function()
					local new_value = clamp_number(control:GetValue() - step, min, max)
					control:SetValue(new_value, true)
					return true
				end,
			},
			IconButton{
				Text = "+",
				IconSize = "M",
				FontSize = "M",
				Padding = "none",
				Mode = "outline",
				OnClick = function()
					local new_value = clamp_number(control:GetValue() + step, min, max)
					control:SetValue(new_value, true)
					return true
				end,
			},
		}
	end

	-- Build slider background drawer
	local draw_background = nil

	if show_slider then
		local slider_height = 2
		draw_background = function(panel, current_value)
			local total_size = panel.transform:GetTotalSize()
			local y = total_size.y - slider_height
			local w = total_size.x
			local t = math.clamp((current_value - min) / (max - min), 0, 1)
			local fill_w = t * w
			theme.active:DrawRoundRect(0, y, w, slider_height, 0, theme.active:GetColor("surface_alt"), 0.3)
			theme.active:DrawRoundRect(0, y, fill_w, slider_height, 0, theme.active:GetColor("primary"), 0.6)
		end
	end

	control = Value{
		Name = node.Name or props.name or "property_number_value",
		Ref = props.Ref,
		Value = tonumber(node.Value) or 0,
		Size = Vec2(props.value_width, props.row_height),
		MinSize = Vec2(props.value_width, props.row_height),
		MaxSize = Vec2(props.value_width, props.row_height),
		Padding = props.padding,
		FontSize = props.font_size,
		Cursor = node.Cursor or "vertical_resize",
		RightElements = right_elements,
		DrawBackground = draw_background,
		layout = props.layout or {
			FitWidth = false,
		},
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
			local drag_step = get_drag_step()
			local rounding_precision = precision

			if input.IsKeyDown("left_alt") or input.IsKeyDown("right_alt") then
				drag_step = drag_step * 0.1
				rounding_precision = precision + drag_precision_boost
			end

			local next_value = (tonumber(start_value) or 0) - delta.y * drag_step

			if input.IsKeyDown("left_control") or input.IsKeyDown("right_control") then
				next_value = math.round(next_value)
			elseif rounding_precision >= 0 then
				next_value = math.round(next_value, rounding_precision)
			end

			return clamp_number(next_value, min, max)
		end,
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

	control:SetValue(node.Value)

	if node.DefaultEncoded ~= nil then
		default_encoded = tostring(node.DefaultEncoded)
	elseif node.Default ~= nil then
		default_encoded = format_number(node.Default, precision)
	else
		default_encoded = control:EncodeValue()
	end

	return control, control
end
