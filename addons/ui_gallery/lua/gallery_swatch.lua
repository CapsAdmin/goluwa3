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

function META:OnCreate(props)
	props.Size = props.Size or Vec2(72, 40)
	props.layout = {MinSize = props.Size, MaxSize = props.Size, props.layout}
	META.BaseClass.OnCreate(self, props)
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
