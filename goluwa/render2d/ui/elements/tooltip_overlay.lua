local Panel = import("goluwa/render2d/ui/panel.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local META = Panel:CreateTemplate("tooltip_overlay")
META.CMP.transform = {}
META.CMP.layout = {
	Floating = true,
	Direction = "y",
	FitWidth = true,
	FitHeight = true,
	Padding = "XS",
}
META.CMP.visual = {Visible = false}
META.CMP.mouse_input = {IgnoreMouseInput = true}
META.CMP.animation = {}

function META:OnDraw()
	theme.active:Draw(self)
end

function META:OnPostDraw()
	theme.active:DrawPost(self)
end

return META:Register()
