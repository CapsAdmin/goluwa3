local Vec2 = import("goluwa/structs/vec2.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local Control = import("goluwa/render2d/ui/widgets/properties/control.lua")
local Number = import("goluwa/render2d/ui/widgets/properties/number.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local META = Panel:CreateTemplate("step_number_value")
META.Base = Control
META.CMP.layout = {
	Direction = "x",
	GrowWidth = 1,
	FitWidth = false,
	ChildGap = "XXS",
	AlignmentY = "center",
}
META:StartStorable()
META:GetSet("Value", 0)
META:GetSet("Min", nil)
META:GetSet("Max", nil)
META:GetSet("Step", nil)
META:GetSet("Precision", 2)
META:GetSet("DragStep", nil)
META:GetSet("DragPrecisionBoost", 2)
META:GetSet("Font", nil)
META:GetSet("FontSize", nil)
META:GetSet("FieldPadding", nil)
META:EndStorable()

local function on_field_change(value, old_value, field)
	field.StepControl.OnChange(value, old_value, field.StepControl)
end

function META:OnCreate(props)
	local size = props.Size or Vec2(92, theme.active:GetInputHeight(props.FontSize or "M"))
	props.Size = size
	props.MinSize = props.MinSize or Vec2(92, size.y)
	props.MaxSize = props.MaxSize or Vec2(0, size.y)
	META.BaseClass.OnCreate(self, props)
	self._field = Number{
		Parent = self,
		IsInternal = true,
		StepControl = self,
		ShowStepper = true,
		StepperVertical = true,
		Value = self.Value,
		Min = self.Min,
		Max = self.Max,
		Step = self.Step,
		Precision = self.Precision,
		DragStep = self.DragStep,
		DragPrecisionBoost = self.DragPrecisionBoost,
		Font = self.Font,
		Padding = self.FieldPadding,
		Size = size,
		MinSize = Vec2(0, size.y),
		MaxSize = Vec2(0, size.y),
		layout = {
			GrowWidth = 1,
			FitWidth = false,
		},
		OnChange = on_field_change,
	}
end

function META:SetValue(value, notify)
	self.Value = value

	if self._field then self._field:SetValue(value, notify) end

	return self
end

function META:GetValue()
	return self._field:GetValue()
end

function META:GetMin()
	return self._field:GetMin()
end

function META:SetMin(value)
	self.Min = value

	if self._field then self._field:SetMin(value) end

	return self
end

function META:GetMax()
	return self._field:GetMax()
end

function META:SetMax(value)
	self.Max = value

	if self._field then self._field:SetMax(value) end

	return self
end

function META:EncodeValue()
	return self._field:EncodeValue()
end

function META:EncodeAny(value)
	return self._field:EncodeAny(value)
end

function META:DecodeValue(text)
	return self._field:DecodeValue(text)
end

return META:Register()
