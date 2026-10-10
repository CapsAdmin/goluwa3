local Vec2 = import("goluwa/structs/vec2.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local Clickable = import("goluwa/render2d/ui/elements/clickable.lua")
local Text = import("goluwa/render2d/ui/elements/text.lua")
local Icon = import("goluwa/render2d/ui/elements/icon.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local META = Panel:CreateTemplate("icon_button")
META.Base = Clickable
META.CMP.layout = {
	FitWidth = false,
	FitHeight = true,
	Direction = "x",
	Padding = "none",
}
META:StartStorable()
META:GetSet("Text", "")
META:GetSet("Font", nil)
META:GetSet("FontSize", nil)
META:GetSet("TextColor", nil)
META:GetSet("Icon", nil)
META:EndStorable()

function META.PropDefaults(_, props)
	local icon_size = props.IconSize or "M"
	return {layout = {MinSize = icon_size, MaxSize = icon_size}}
end

function META:OnCreate()
	META.BaseClass.OnCreate(self)
	local icon_size = self.IconSize or "M"

	if self.Icon then
		Icon{
			Parent = self,
			IsInternal = true,
			Icon = self.Icon,
			Size = icon_size,
			MinSize = icon_size,
			MaxSize = icon_size,
			IconColor = self.TextColor,
			layout = {
				GrowWidth = 0,
				FitWidth = false,
				FitHeight = false,
			},
		}
	elseif self.Text ~= "" then
		Text{
			Parent = self,
			IsInternal = true,
			Text = self.Text,
			Font = self.Font,
			FontSize = self.FontSize,
			Color = self.TextColor,
			AlignX = 0.5,
			AlignY = 0.5,
			IgnoreMouseInput = true,
			layout = {
				FitWidth = false,
				FitHeight = false,
			},
		}
	end
end

function META:PreRemoveChildren()
	self:RemoveExternalChildren()
	return false
end

return META:Register()
