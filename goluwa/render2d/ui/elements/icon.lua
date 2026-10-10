local Panel = import("goluwa/render2d/ui/panel.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local META = Panel:CreateTemplate("icon")
META.CMP.transform = {Size = "icon"}
META.CMP.visual = {}
META.CMP.style = {}
META.CMP.mouse_input = {IgnoreMouseInput = true}
META:StartStorable()
META:GetSet("Icon", "disclosure")
META:GetSet("IconColor", nil)
META:GetSet("OpenFraction", 0)
META:EndStorable()

function META:OnDraw()
	theme.active:DrawIcon(
		self.Icon,
		self.transform:GetSize(),
		{
			color = theme.active:ResolveColor(self.IconColor or self.style:GetResolvedForegroundColor(), "text"),
			open_fraction = self.OpenFraction,
		}
	)
end

return META:Register()
