local Panel = import("goluwa/render2d/ui/panel.lua")
local Clickable = import("goluwa/render2d/ui/elements/clickable.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local META = Panel:CreateTemplate("property_swatch")
META.Base = Clickable
META:StartStorable()
META:GetSet("Color", nil)
META:EndStorable()

function META:OnCreate(props)
	META.BaseClass.OnCreate(self, props)
	self:SetState("theme_role", "property_preview")
end

function META:OnDraw()
	self:SetState("preview_fill", self.Color)
	self:SetState("preview_radius", theme.active:GetRadius("M"))
	theme.active:Draw(self)
end

function META:OnPostDraw() end

return META:Register()
