local Vec2 = import("goluwa/structs/vec2.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local Control = import("goluwa/render2d/ui/widgets/properties/control.lua")
local Button = import("goluwa/render2d/ui/widgets/button.lua")
local TextEdit = import("goluwa/render2d/ui/elements/text_edit.lua")
local META = Panel:CreateTemplate("property_text")
META.Base = Control
META.CMP.layout = {
	Direction = "x",
	FitWidth = false,
	FitHeight = true,
	GrowWidth = 1,
	AlignmentY = "center",
	AlignmentX = "stretch",
}
META:StartStorable()
META:GetSet("Value", "")
META:GetSet("ApplyText", "Apply")
META:GetSet("FontSize", nil)
META:GetSet("FieldPadding", nil)
META:GetSet("ValueWidth", 200)
META:GetSet("RowHeight", 60)
META:EndStorable()

local function on_apply_click(button)
	local control = button.Control
	control:SetValue(control._edit:GetText(), true)
end

function META:OnCreate(props)
	META.BaseClass.OnCreate(self, props)
	local size = Vec2(self.ValueWidth, self.RowHeight)
	self._edit = TextEdit{
		Parent = self,
		IsInternal = true,
		Text = self.Value,
		FontSize = self.FontSize,
		Size = size,
		MinSize = size,
		MaxSize = Vec2(0, size.y),
		Padding = self.FieldPadding,
		Wrap = true,
		ScrollY = true,
		layout = {FitWidth = false, GrowWidth = 1},
	}
	Button{
		Parent = self,
		IsInternal = true,
		Control = self,
		Text = self.ApplyText,
		FontSize = self.FontSize,
		Padding = self.FieldPadding,
		Mode = "outline",
		OnClick = on_apply_click,
		layout = {SelfAlignmentY = "center"},
	}
end

function META:SetValue(value, notify)
	local old_value = self.Value
	self.Value = value == nil and "" or tostring(value)

	if self._edit then self._edit:SetText(self.Value) end

	if notify and old_value ~= self.Value then
		self.OnChange(self.Value, old_value, self)
	end

	return self
end

function META:GetValue()
	if self._edit then return self._edit:GetText() end

	return self.Value
end

function META:EncodeValue()
	return self:GetValue()
end

function META:DecodeValue(text)
	return tostring(text or ""), true
end

return META:Register()
