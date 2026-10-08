local Panel = import("goluwa/render2d/ui/panel.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local META = Panel:CreateTemplate("frame")
META.CMP.transform = {}
META.CMP.layout = {}
META.CMP.visual = {}
META.CMP.mouse_input = {}
META.CMP.clickable = {}
META.CMP.animation = {}
META:StartStorable()

META:GetSet("Emphasis", 0, function(self, val)
	self:SetState("emphasis", val)
end)

META:EndStorable()

function META:OnCreate(props)
	META.BaseClass.OnCreate(self, props)
	self:SetState("emphasis", self.Emphasis)

	if props.OnClick then self.mouse_input:SetCursor("pointer") end
end

function META:OnDraw()
	theme.active:Draw(self)
end

function META:OnPostDraw()
	theme.active:DrawPost(self)
end

return META:Register()
