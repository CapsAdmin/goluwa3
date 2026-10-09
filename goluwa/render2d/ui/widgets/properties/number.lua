local Panel = import("goluwa/render2d/ui/panel.lua")
local Value = import("goluwa/render2d/ui/widgets/properties/value.lua")
local IconButton = import("goluwa/render2d/ui/widgets/icon_button.lua")
local Row = import("goluwa/render2d/ui/elements/row.lua")
local Column = import("goluwa/render2d/ui/elements/column.lua")
local input = import("goluwa/input.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local system = import("goluwa/system.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local META = Panel:CreateTemplate("property_number")
META.Base = Value
META.Cursor = "vertical_resize"
META.EditClickCount = 2
META:StartStorable()
META:GetSet("Min", nil)
META:GetSet("Max", nil)
META:GetSet("Step", nil)
META:GetSet("Precision", 2)
META:GetSet("Integer", false)
META:GetSet("DragStep", nil)
META:GetSet("DragPrecisionBoost", 2)
META:GetSet("ShowStepper", false)
META:GetSet("StepperVertical", false)
META:GetSet("ShowSlider", false)
META:EndStorable()

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

local function draw_slider_background(field, value)
	local slider_height = theme.active:GetSize("XXXS")
	local total_size = field.transform:GetTotalSize()
	local y = total_size.y - slider_height
	local min = field:GetMin()
	local max = field:GetMax()
	local fraction = math.clamp((value - min) / (max - min), 0, 1)
	theme.active:DrawRoundRect(0, y, total_size.x, slider_height, 0, theme.active:GetColor("surface_alt"), 0.3)
	theme.active:DrawRoundRect(
		0,
		y,
		fraction * total_size.x,
		slider_height,
		0,
		theme.active:GetColor("primary"),
		0.6
	)
end

local function on_step_click(button)
	button.Field:Increment(button.StepDirection)
	return true
end

function META.PropDefaults(_, props)
	return {Step = props.Integer and 1 or nil}
end

function META:OnCreate()
	local stepper

	if self.ShowStepper then
		stepper = (
			self.StepperVertical and
			Column or
			Row
		){
			layout = {
				ChildGap = self.StepperVertical and "XXXS" or "XXS",
				FitWidth = true,
				GrowWidth = 0,
				AlignmentX = "stretch",
			},
		}
		self.RightElements = {stepper}
	end

	if self.Integer then self:SetPrecision(0) end

	META.BaseClass.OnCreate(self)
	self._stepper = stepper

	if stepper then
		for _, step in ipairs(self.StepperVertical and {{"+", 1}, {"-", -1}} or {{"-", -1}, {"+", 1}}) do
			IconButton{
				Parent = stepper,
				Field = self,
				StepDirection = step[2],
				Text = step[1],
				IconSize = "M",
				FontSize = "XS",
				Padding = "none",
				Mode = "outline",
				OnClick = on_step_click,
			}
		end
	end

	if self.ShowSlider then self.DrawBackground = draw_slider_background end

	self:SetValue(self.Value)
end

function META:OnEditingChanged(editing)
	if not self._stepper then return end

	for _, button in ipairs(self._stepper:GetChildren()) do
		button.visual:SetVisible(not editing)
	end
end

function META:GetMin()
	return self.Min or -math.huge
end

function META:GetMax()
	return self.Max or math.huge
end

function META:SetMin(value)
	self.Min = value
	self:SetValue(self.Value)
	return self
end

function META:SetMax(value)
	self.Max = value
	self:SetValue(self.Value)
	return self
end

function META:Increment(direction)
	return self:SetValue(self:GetValue() + direction * self:get_step(), true)
end

function META:get_step()
	if self.Step then return self.Step end

	if self.Precision > 0 then return 10 ^ -self.Precision end

	return 1
end

function META:get_display_precision()
	if self:IsDragging() and input.IsAltDown() then
		return self.Precision + self.DragPrecisionBoost
	end

	return self.Precision
end

do
	local PIXELS_PER_STEP = 4
	local ACCELERATION_SPEED = 600
	local MAX_ACCELERATION = 64

	function META:get_drag_rate()
		if self.DragStep then return self.DragStep, false end

		local fixed_rate = self:get_step() / PIXELS_PER_STEP
		local min = self:GetMin()
		local max = self:GetMax()

		if min ~= -math.huge and max ~= math.huge then
			local screen_rate = (max - min) / select(2, render2d.GetSize())

			if screen_rate <= fixed_rate then return screen_rate, false end
		end

		return fixed_rate, true
	end

	function META.OnDragValue(frame_delta, field)
		local rate, accelerate = field:get_drag_rate()
		local precision = field.Precision

		if accelerate then
			local speed = math.abs(frame_delta.y) / math.max(system.GetFrameTime(), 1 / 240)
			rate = rate * math.min(1 + (speed / ACCELERATION_SPEED) ^ 2, MAX_ACCELERATION)
		end

		if input.IsAltDown() then
			rate = rate * 0.1
			precision = precision + field.DragPrecisionBoost
		end

		if input.IsShiftDown() then rate = rate * 10 end

		local value = math.clamp(field._drag_value - frame_delta.y * rate, field:GetMin(), field:GetMax())
		field._drag_value = value

		if input.IsControlDown() then
			value = math.round(value)
		elseif precision >= 0 then
			value = math.round(value, precision)
		end

		return value
	end
end

function META.FormatValue(value, field)
	return format_number(value, field:get_display_precision())
end

function META:SetValue(value, notify)
	local numeric = tonumber(value) or 0
	return META.BaseClass.SetValue(self, math.clamp(numeric, self:GetMin(), self:GetMax()), notify)
end

function META:EncodeAny(value)
	return format_number(value, self.Precision)
end

function META:EncodeValue()
	return format_number(self.Value, self.Precision)
end

function META:format_edit_value(value)
	return format_number(value, self:get_display_precision())
end

function META.ParseValue(text, current_value, field)
	local numeric = tonumber(text)

	if numeric == nil then return current_value end

	return math.clamp(numeric, field:GetMin(), field:GetMax())
end

function META:DecodeValue(text)
	local numeric = tonumber(text)

	if numeric == nil then return nil, false end

	return math.clamp(numeric, self:GetMin(), self:GetMax()), true
end

return META:Register()
