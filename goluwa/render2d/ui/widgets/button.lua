local Vec2 = import("goluwa/structs/vec2.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local Clickable = import("goluwa/render2d/ui/elements/clickable.lua")
local Text = import("goluwa/render2d/ui/elements/text.lua")
local Icon = import("goluwa/render2d/ui/elements/icon.lua")
local META = Panel:CreateTemplate("button")
META.Base = Clickable
META.CMP.layout = {FitWidth = true, FitHeight = true}
META:StartStorable()
META:GetSet("Text", "")
META:GetSet("Icon", nil)
META:GetSet("IconTexture", nil)
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
	local layout = {}

	if props.Padding == nil and (props.Mode or self.Mode) ~= "menu" then
		layout.MinSize = theme.Dynamic(theme.InputSize, 0, props.FontSize)
	end

	if props.Icon or props.IconTexture then layout.ChildGap = "XS" end

	return {layout = layout}
end

function META:OnCreate()
	META.BaseClass.OnCreate(self)

	if self.Icon or self.IconTexture then
		local size = self.IconTexture and Vec2(28, 28) or "icon"
		Icon{
			Parent = self,
			IsInternal = true,
			Icon = self.Icon,
			Texture = self.IconTexture,
			Size = size,
			MinSize = size,
			MaxSize = size,
			IconColor = self.TextColor,
			layout = {GrowWidth = 0, FitWidth = false},
		}
	end

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

return META:Register()
