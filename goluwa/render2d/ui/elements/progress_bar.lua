local Vec2 = import("goluwa/structs/vec2.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local META = Panel:CreateTemplate("progress_bar")
META.CMP.transform = {}
META.CMP.layout = {}
META.CMP.visual = {}
META:StartStorable()
META:GetSet("Value", 0)
META:GetSet("Color", nil)
META:EndStorable()

function META:SetValue(val)
	self.Value = math.clamp(val, 0, 1)
	self:SetState("value", self.Value)
end

function META:OnCreate(props)
	local height = theme.active:GetSize("M")
	props.Size = props.Size or Vec2(200, height)
	props.layout = {MinSize = Vec2(100, height), props.layout}
	META.BaseClass.OnCreate(self, props)
	self:SetValue(self.Value)
	self:SetState("color", self.Color)
end

function META:OnDraw()
	theme.active:Draw(self)
end

return META:Register()
