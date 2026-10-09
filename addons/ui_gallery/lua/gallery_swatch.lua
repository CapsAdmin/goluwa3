local Vec2 = import("goluwa/structs/vec2.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local META = Panel:CreateTemplate("gallery_swatch")
META.CMP.transform = {}
META.CMP.layout = {
	FitWidth = false,
	FitHeight = false,
}
META.CMP.visual = {}
META.CMP.mouse_input = {IgnoreMouseInput = true}
META:StartStorable()
META:GetSet("Token", "primary")
META:GetSet("Radius", nil)
META:EndStorable()

function META.PropDefaults(_, props)
	local size = props.Size or Vec2(72, 40)
	return {Size = size, layout = {MinSize = size, MaxSize = size}}
end

function META:OnDraw()
	theme.active:DrawBox(
		self.transform:GetSize(),
		{
			fill = self.Token,
			outline = "border",
			radius = theme.active:GetRadius(self.Radius or "S"),
		}
	)
end

return META:Register()
