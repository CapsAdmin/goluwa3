local Panel = import("goluwa/render2d/ui/panel.lua")
local Text = import("goluwa/render2d/ui/elements/text.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local META = Panel:CreateTemplate("checkable")
META.BoxName = "checkbox"
META.CMP.transform = {}
META.CMP.layout = {
	Direction = "x",
	AlignmentY = "center",
	ChildGap = "S",
	FitWidth = true,
	FitHeight = true,
	GrowWidth = 0,
}
META.CMP.visual = {}
META.CMP.mouse_input = {Cursor = "hand"}
META.CMP.clickable = {}
META:StartStorable()
META:GetSet("Value", false)
META:GetSet("Text", "")
META:GetSet("Font", nil)
META:GetSet("FontSize", nil)
META:GetSet("TextColor", nil)
META:GetSet("Disabled", false)
META:EndStorable()

local function draw_box(box)
	render2d.PushAlphaMultiplier(box.visual:GetDrawAlpha())
	theme.active:Draw(box)
	render2d.PopAlphaMultiplier()
end

function META:SetValue(value)
	self.Value = value
	self:SetState("value", value)
	return self
end

function META:SetText(text)
	self.Text = text

	if not self._box then return self end

	if self._label then
		self._label.text:SetText(text)
	elseif text ~= "" then
		self:create_label()
	end

	return self
end

function META:SetDisabled(disabled)
	self.Disabled = disabled
	self.clickable:SetDisabled(disabled)
	self.mouse_input:SetCursor(disabled and "arrow" or "hand")

	for _, child in ipairs(self:GetChildren()) do
		child.visual:SetDrawAlpha(disabled and 0.5 or 1)
	end

	return self
end

function META:create_label()
	self._label = Text{
		Parent = self,
		IsInternal = true,
		Text = self.Text,
		Font = self.Font,
		FontSize = self.FontSize,
		Color = self.TextColor,
		IgnoreMouseInput = true,
	}
	self._label.visual:SetDrawAlpha(self.Disabled and 0.5 or 1)
end

function META:OnCreate()
	META.BaseClass.OnCreate(self)
	self._box = Panel.New{
		Parent = self,
		IsInternal = true,
		Name = self.BoxName,
		transform = {Size = "M"},
		visual = true,
		animation = true,
		mouse_input = {IgnoreMouseInput = true},
		OnDraw = draw_box,
	}
	self._box:SetState("hovered", false)
	self._box:SetState("value", self:IsChecked())

	if self.Text ~= "" then self:create_label() end

	self:SetDisabled(self.Disabled)
	self:SetValue(self.Value)
end

function META:IsChecked()
	return self.Value
end

function META:OnHover(hovered)
	self._box:SetState("hovered", hovered)
end

function META:OnDraw()
	self._box:SetState("value", self:IsChecked())
end

return META:Register()
