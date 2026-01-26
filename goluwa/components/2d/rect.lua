local prototype = require("prototype")
local event = require("event")
local ecs = require("ecs")
local render2d = require("render2d.render2d")
local gfx = require("render2d.gfx")
local Color = require("structs.color")
local Vec2 = require("structs.vec2")
local transform = require("components.2d.transform").Component
local META = prototype.CreateTemplate("rect_2d")
META.ComponentName = "rect_2d"
META.Require = {transform}
META:StartStorable()
META:GetSet("Color", Color(1, 1, 1, 1))
META:GetSet("Visible", true)
META:GetSet("Texture", nil)
META:GetSet("Clipping", false)
META:GetSet("ShadowSize", 16)
META:GetSet("BorderRadius", 0)
META:GetSet("Shadows", false)
META:GetSet("ShadowColor", Color(0, 0, 0, 0.5))
META:GetSet("ShadowOffset", Vec2(0, 0))
META:GetSet("DrawColor", Color(0, 0, 0, 0))
META:GetSet("DrawAlpha", 1)
META:EndStorable()

function META:Initialize() end

function META:SetColor(c)
	if type(c) == "string" then
		self.Color = Color.FromHex(c)
	else
		self.Color = c
	end
end

function META:DrawShadow()
	if not self.Shadows then return end

	local transform = self.Entity.transform_2d
	render2d.PushMatrix()
	render2d.SetWorldMatrix(transform:GetWorldMatrix())
	local s = transform.Size + transform.DrawSizeOffset
	render2d.SetBlendMode("alpha")
	render2d.SetColor(self.ShadowColor:Unpack())
	gfx.DrawShadow(self.ShadowOffset.x, self.ShadowOffset.y, s.x, s.y, self.ShadowSize, self.BorderRadius)
	render2d.PopMatrix()
end

function META:OnDraw()
	local transform = self.Entity.transform_2d
	local s = transform.Size + transform.DrawSizeOffset
	render2d.SetTexture(self.Texture)
	local c = self.Color + self.DrawColor
	render2d.SetColor(c.r, c.g, c.b, c.a * self.DrawAlpha)

	if self.BorderRadius > 0 then
		gfx.DrawRoundedRect(0, 0, s.x, s.y, self.BorderRadius)
	else
		render2d.DrawRect(0, 0, s.x, s.y)
	end

	render2d.SetColor(0, 0, 0, 1)
end

function META:OnPostDraw() end

function META:DrawRecursive()
	if not self.Visible then return end

	self:DrawShadow()
	local transform = self.Entity.transform_2d
	local clipping = self.Clipping

	if clipping then
		render2d.PushStencilMask()
		render2d.PushMatrix()
		render2d.SetWorldMatrix(transform:GetWorldMatrix())
		render2d.DrawRect(0, 0, transform.Size.x, transform.Size.y)
		render2d.PopMatrix()
		render2d.BeginStencilTest()
	end

	render2d.PushMatrix()
	render2d.SetWorldMatrix(transform:GetWorldMatrix())
	self:OnDraw()

	for _, child in ipairs(self.Entity:GetChildren()) do
		local child_rect = child:GetComponent("rect_2d")

		if child_rect then child_rect:DrawRecursive() end
	end

	if clipping then render2d.PopStencilMask() end

	self:OnPostDraw()
	render2d.PopMatrix()
end

function META:IsHovered(mouse_pos)
	local transform = self.Entity.transform_2d
	local local_pos = transform:GlobalToLocal(mouse_pos)
	return local_pos.x >= 0 and
		local_pos.y >= 0 and
		local_pos.x <= transform.Size.x and
		local_pos.y <= transform.Size.y
end

local rect_2d = {}

function rect_2d.StartSystem()
	print("Starting rect_2d system")

	event.AddListener("Draw2D", "ecs_gui_system", function()
		local world = ecs.Get2DWorld()

		if not world then return end

		for _, child in ipairs(world:GetChildren()) do
			local rect = child:GetComponent("rect_2d")

			if rect then rect:DrawRecursive() end
		end
	end)
end

function rect_2d.StopSystem()
	print("Stopping rect_2d system")
	event.RemoveListener("Draw2D", "ecs_gui_system")
end

rect_2d.Component = META:Register()
return rect_2d
