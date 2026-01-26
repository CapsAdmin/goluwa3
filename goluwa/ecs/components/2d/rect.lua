local prototype = require("prototype")
local event = require("event")
local ecs = require("ecs.ecs")
local render2d = require("render2d.render2d")
local gfx = require("render2d.gfx")
local Color = require("structs.color")
local Vec2 = require("structs.vec2")
local transform = require("ecs.components.2d.transform")
local gui_element_2d = require("ecs.components.2d.gui_element")
local META = prototype.CreateTemplate("rect_2d")
META.ComponentName = "rect_2d"
META.Require = {transform, gui_element_2d.Component}
META:StartStorable()
META:GetSet("Color", Color(1, 1, 1, 1))
META:GetSet("Texture", nil)
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

function META:OnDraw()
	local transform = self.Entity.transform_2d
	local s = transform.Size + transform.DrawSizeOffset
	render2d.SetTexture(self.Texture)
	local c = self.Color + self.DrawColor
	render2d.SetColor(c.r, c.g, c.b, c.a * self.DrawAlpha)

	if self.Color.a > 0 or self.Texture then
		local borderRadius = self.Entity.gui_element_2d:GetBorderRadius()

		if borderRadius > 0 then
			gfx.DrawRoundedRect(0, 0, s.x, s.y, borderRadius)
		else
			render2d.DrawRect(0, 0, s.x, s.y)
		end
	end

	render2d.SetColor(0, 0, 0, 1)
end

local rect_2d = {}
rect_2d.Component = META:Register()
return rect_2d
