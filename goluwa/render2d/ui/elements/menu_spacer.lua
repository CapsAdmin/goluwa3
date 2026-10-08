local Vec2 = import("goluwa/structs/vec2.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local META = Panel:CreateTemplate("menu_spacer")
META.CMP.transform = {}
META.CMP.layout = {
	FitWidth = false,
	FitHeight = false,
}
META.CMP.visual = {}
META.CMP.mouse_input = {IgnoreMouseInput = true}
META:StartStorable()
META:GetSet("Vertical", false)
META:GetSet("Thickness", nil)
META:EndStorable()

function META:OnCreate(props)
	META.BaseClass.OnCreate(self, props)
	local thickness = theme.active:ResolveSize(self.Thickness or "XS")

	if self.Vertical then
		self.transform:SetSize(Vec2(thickness, 0))
		self.layout:SetGrowWidth(0)
		self.layout:SetGrowHeight(1)
	else
		self.transform:SetSize(Vec2(0, thickness))
		self.layout:SetGrowWidth(1)
		self.layout:SetGrowHeight(0)
	end

	self:SetState("vertical", self.Vertical)
end

function META:OnDraw()
	theme.active:Draw(self)
end

return META:Register()
