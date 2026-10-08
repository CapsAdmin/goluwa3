local Panel = import("goluwa/render2d/ui/panel.lua")
local Control = import("goluwa/render2d/ui/widgets/properties/control.lua")
local Checkbox = import("goluwa/render2d/ui/elements/checkbox.lua")
local META = Panel:CreateTemplate("property_boolean")
META.Base = Control
META.CMP.layout = {
	Direction = "x",
	AlignmentY = "center",
	ChildGap = "S",
	FitWidth = false,
	FitHeight = true,
	GrowWidth = 1,
}
META.CMP.visual = {}
META.CMP.mouse_input = {Cursor = "hand"}
META.CMP.clickable = {}
META.CMP.animation = {}
META:StartStorable()
META:GetSet("Value", false)
META:GetSet("FontSize", nil)
META:EndStorable()

local function on_checkbox_change(value, checkbox)
	checkbox.Control:SetValue(value, true)
end

function META:OnCreate(props)
	META.BaseClass.OnCreate(self, props)
	self._checkbox = Checkbox{
		Parent = self,
		IsInternal = true,
		Control = self,
		Text = self.Value and "true" or "false",
		FontSize = self.FontSize,
		Value = self.Value,
		OnChange = on_checkbox_change,
	}
end

function META:SetValue(value, notify)
	local old_value = self.Value
	self.Value = value

	if self._checkbox then
		self._checkbox:SetValue(value, false)
		self._checkbox:SetText(value and "true" or "false")
	end

	if notify and old_value ~= value then self.OnChange(value, old_value, self) end

	return self
end

function META:GetValue()
	return self.Value
end

function META:EncodeValue()
	return self.Value and "true" or "false"
end

function META:EncodeAny(value)
	return value and "true" or "false"
end

function META:DecodeValue(text)
	local normalized = tostring(text or ""):match("^%s*(.-)%s*$"):lower()

	if
		normalized == "true" or
		normalized == "1" or
		normalized == "yes" or
		normalized == "on"
	then
		return true, true
	end

	if
		normalized == "false" or
		normalized == "0" or
		normalized == "no" or
		normalized == "off"
	then
		return false, true
	end

	return nil, false
end

function META:OnClick()
	self:SetValue(not self.Value, true)
end

function META:OnHover(hovered)
	self._checkbox:OnHover(hovered)
end

return META:Register()
