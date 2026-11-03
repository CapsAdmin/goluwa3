local Vec2 = import("goluwa/structs/vec2.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local system = import("goluwa/system.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local META = Panel:CreateTemplate("ghost")
META.CMP.transform = {}
META.CMP.visual = {}
META.CMP.mouse_input = {IgnoreMouseInput = true}
META.CMP.layout = {Floating = true}
META:StartStorable()
META:GetSet("Alpha", 0.6)
META:GetSet("Radius", 0)
META:GetSet("BackgroundColor", "surface")
META:GetSet("BackgroundAlpha", 0.9)
META:EndStorable()
META:GetSet("Source", nil)
META:GetSet("GrabPosition", nil)

local function unghost_source(ghost)
	if ghost.Source:IsValid() then ghost.Source.visual:SetGhosted(false) end
end

function META:OnCreate()
	META.BaseClass.OnCreate(self)
	local grab = self.GrabPosition or system.GetWindow():GetMousePosition()
	self.Grab = grab - self.Source.transform:LocalToGlobal(Vec2(0, 0))
	self.Source.visual:SetGhosted(true)
	self:CallOnRemove(unghost_source, "unghost_source")
	self:BringToFront()
end

function META:OnDraw()
	local source = self.Source

	if not source:IsValid() then return end

	local mouse = system.GetWindow():GetMousePosition()
	local origin = source.transform:LocalToGlobal(Vec2(0, 0))
	local x = mouse.x - self.Grab.x
	local y = mouse.y - self.Grab.y
	local size = source.transform:GetSize()
	local active = theme.active
	render2d.PushMatrix(x, y, nil, nil, nil, true)
	active:DrawRoundRect(
		0,
		0,
		size.x,
		size.y,
		self.Radius,
		active:GetColor(self.BackgroundColor),
		self.BackgroundAlpha
	)
	render2d.PopMatrix()
	source.visual:DrawGhost(x - origin.x, y - origin.y, self.Alpha)
end

return META:Register()
