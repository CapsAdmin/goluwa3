local prototype = require("prototype")
local event = require("event")
local render2d = require("render2d.render2d")
local gfx = require("render2d.gfx")
local Color = require("structs.color")
local Vec2 = require("structs.vec2")
local META = prototype.CreateTemplate("gui_element")
META:StartStorable()
META:GetSet("Visible", true)
META:GetSet("Clipping", false)
META:GetSet("Shadows", false)
META:GetSet("ShadowSize", 16)
META:GetSet("ShadowColor", Color(0, 0, 0, 0.5))
META:GetSet("ShadowOffset", Vec2(0, 0))
META:GetSet("BorderRadius", 0)
META:EndStorable()

function META:Initialize() end

function META:SetVisible(visible)
	self.Visible = visible

	if self.Owner.OnVisibilityChanged then
		self.Owner:OnVisibilityChanged(visible)
	end
end

function META:DrawShadow()
	if not self:GetShadows() then return end

	local transform = self.Owner.transform
	render2d.PushMatrix()
	render2d.SetWorldMatrix(transform:GetWorldMatrix())
	local s = transform.Size + transform.DrawSizeOffset
	render2d.SetBlendMode("alpha")
	render2d.SetColor(self:GetShadowColor():Unpack())
	gfx.DrawShadow(
		self:GetShadowOffset().x,
		self:GetShadowOffset().y,
		s.x,
		s.y,
		self:GetShadowSize(),
		self:GetBorderRadius()
	)
	render2d.PopMatrix()
end

function META:IsHovered(mouse_pos)
	local transform = self.Owner.transform
	local local_pos = transform:GlobalToLocal(mouse_pos)
	return local_pos.x >= 0 and
		local_pos.y >= 0 and
		local_pos.x <= transform.Size.x and
		local_pos.y <= transform.Size.y
end

function META:DrawRecursive()
	if not self:GetVisible() then return end

	self:DrawShadow()
	local transform = self.Owner.transform
	local clipping = self:GetClipping()

	if clipping then
		render2d.PushStencilMask()
		render2d.PushMatrix()
		render2d.SetWorldMatrix(transform:GetWorldMatrix())

		if self:GetBorderRadius() > 0 then
			gfx.DrawRoundedRect(0, 0, transform.Size.x, transform.Size.y, self:GetBorderRadius())
		else
			render2d.DrawRect(0, 0, transform.Size.x, transform.Size.y)
		end

		render2d.PopMatrix()
		render2d.BeginStencilTest()
	end

	render2d.PushMatrix()
	render2d.SetWorldMatrix(transform:GetWorldMatrix())
	self.Owner:CallLocalEvent("OnDraw")
	self:OnDraw()

	for _, child in ipairs(self.Owner:GetChildren()) do
		if child.gui_element then child.gui_element:DrawRecursive() end
	end

	if clipping then
		render2d.SetStencilMode("mask_decrement", render2d.stencil_level)
		render2d.PushMatrix()
		render2d.SetWorldMatrix(transform:GetWorldMatrix())

		if self:GetBorderRadius() > 0 then
			gfx.DrawRoundedRect(0, 0, transform.Size.x, transform.Size.y, self:GetBorderRadius())
		else
			render2d.DrawRect(0, 0, transform.Size.x, transform.Size.y)
		end

		render2d.PopMatrix()
		render2d.PopStencilMask()
	end

	self.Owner:CallLocalEvent("OnPostDraw")
	self:OnPostDraw()
	render2d.PopMatrix()
end

function META:OnDraw() end

function META:OnPostDraw() end

function META:OnFirstCreated()
	event.AddListener("Draw2D", "ecs_gui_system", function()
		self.Owner:GetRoot().gui_element:DrawRecursive()
	end)
end

function META:OnLastRemoved()
	event.RemoveListener("Draw2D", "ecs_gui_system")
end

return META:Register()
