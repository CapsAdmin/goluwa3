local Vec2 = import("goluwa/structs/vec2.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local Clickable = import("goluwa/render2d/ui/elements/clickable.lua")
local Text = import("goluwa/render2d/ui/elements/text.lua")
local META = Panel:CreateTemplate("button")
META.Base = Clickable
META.CMP.layout = {FitWidth = true, FitHeight = true}
META:StartStorable()
META:GetSet("Text", "")
META:GetSet("Font", nil)
META:GetSet("FontSize", nil)
META:GetSet("TextColor", nil)
META:GetSet("AlignX", 0.5)
META:GetSet("AlignY", 0.5)
META:EndStorable()

function META:SetText(text)
	self.Text = text

	if self.label then self.label.text:SetText(text) end

	return self
end

function META:PropDefaults(props)
	if props.Padding == nil and (props.Mode or self.Mode) ~= "menu" then
		return {layout = {MinSize = theme.Dynamic(theme.InputSize, 0, props.FontSize)}}
	end

	return {}
end

function META:OnCreate()
	META.BaseClass.OnCreate(self)
	self.label = Text{
		Parent = self,
		IsInternal = true,
		Text = self.Text,
		Font = self.Font,
		Color = self.TextColor,
		AlignX = self.AlignX,
		AlignY = self.AlignY,
		IgnoreMouseInput = true,
		layout = self.TextLayout,
	}
end

function META:PreRemoveChildren()
	self:RemoveExternalChildren()
	return false
end

return META:Register()
