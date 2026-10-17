local Panel = import("goluwa/render2d/ui/panel.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local render2d = import("goluwa/render2d/render2d.lua")
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
-- a texture is drawn instead of the theme icon
META:GetSet("Texture", nil)

function META:OnDraw()
	local texture = self.Texture

	if texture then
		if texture:IsReady() then
			local size = self.transform:GetSize()
			render2d.SetTexture(texture)
			render2d.SetColor(1, 1, 1, 1)
			render2d.DrawRect(0, 0, size.x, size.y)
			render2d.SetTexture(nil)
		end

		return
	end

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
