local Panel = import("goluwa/render2d/ui/panel.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local META = Panel:CreateTemplate("menu_container")
META.ThemeName = "menu_container"
META.CMP.transform = {}
META.CMP.layout = {
	Direction = "y",
	GrowWidth = 1,
	FitHeight = true,
	AlignmentX = "stretch",
	ChildGap = "none",
	Padding = "none",
}
META.CMP.visual = {}
META.CMP.mouse_input = {}
META.CMP.clickable = {}
META.CMP.animation = {}
META.CMP.style = {}

function META:OnCreate()
	META.BaseClass.OnCreate(self)
	self.style:SetForegroundColor(theme.active:GetContentForeground())
end

function META:OnThemeChanged()
	self.style:SetForegroundColor(theme.active:GetContentForeground())
end

function META:OnDraw()
	theme.active:Draw(self)
end

return META:Register()
