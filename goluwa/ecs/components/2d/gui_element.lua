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
META:GetSet("BorderRadius", 0)
META:GetSet("Color", Color(1, 1, 1, 1))
META:GetSet("DrawColor", Color(0, 0, 0, 0))
META:GetSet("DrawAlpha", 1)
META:EndStorable()

function META:Initialize()
	self.Owner:EnsureComponent("transform")
end

function META:SetColor(c)
	if type(c) == "string" then
		self.Color = Color.FromHex(c)
	else
		self.Color = c
	end
end

function META:SetVisible(visible)
	self.Visible = visible
	self.Owner:CallLocalEvent("OnVisibilityChanged", visible)
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

	local c = self.Color + self.DrawColor

	if c.a <= 0 then return end

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
	render2d.SetColor(c.r, c.g, c.b, c.a * self.DrawAlpha)
	self.Owner:CallLocalEvent("OnDraw")

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
	render2d.PopMatrix()
end

function META:OnFirstCreated()
	event.AddListener("Draw2D", "ecs_gui_system", function()
		self.Owner:GetRoot().gui_element:DrawRecursive()
	end)
end

function META:OnLastRemoved()
	event.RemoveListener("Draw2D", "ecs_gui_system")
end

return META:Register()
