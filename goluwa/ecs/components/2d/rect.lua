local prototype = require("prototype")
local event = require("event")
local render2d = require("render2d.render2d")
local gfx = require("render2d.gfx")
local Color = require("structs.color")
local Vec2 = require("structs.vec2")
local META = prototype.CreateTemplate("rect")
META:StartStorable()
META:GetSet("Color", Color(1, 1, 1, 1))
META:GetSet("Texture", nil)
META:GetSet("DrawColor", Color(0, 0, 0, 0))
META:GetSet("DrawAlpha", 1)
META:EndStorable()

function META:Initialize()
	self.Owner:EnsureComponent("gui_element")
	self.Owner:EnsureComponent("transform")

	self.Owner:AddLocalListener("OnDraw", function()
		self:OnDraw()
	end)
end

function META:SetColor(c)
	if type(c) == "string" then
		self.Color = Color.FromHex(c)
	else
		self.Color = c
	end
end

function META:OnDraw()
	local transform = self.Owner.transform
	local s = transform.Size + transform.DrawSizeOffset
	render2d.SetTexture(self.Texture)
	local c = self.Color + self.DrawColor
	render2d.SetColor(c.r, c.g, c.b, c.a * self.DrawAlpha)

	if self.Color.a > 0 or self.Texture then
		local borderRadius = self.Owner.gui_element:GetBorderRadius()

		if borderRadius > 0 then
			gfx.DrawRoundedRect(0, 0, s.x, s.y, borderRadius)
		else
			render2d.DrawRect(0, 0, s.x, s.y)
		end
	end

	render2d.SetColor(0, 0, 0, 1)
end

return META:Register()
