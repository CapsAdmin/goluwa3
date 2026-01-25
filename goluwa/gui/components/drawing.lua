local Color = require("structs.color")
local render2d = require("render2d.render2d")
local gfx = require("render2d.gfx")
local Vec2 = require("structs.vec2")
return function(META)
	META:StartStorable()
	META:GetSet("Clipping", false)
	META:GetSet("Visible", true)
	META:GetSet("Color", Color(1, 1, 1, 1))
	META:GetSet("ShadowSize", 16)
	META:GetSet("BorderRadius", 0)
	META:GetSet("Shadows", false)
	META:GetSet("ShadowColor", Color(0, 0, 0, 0.5))
	META:GetSet("ShadowOffset", Vec2(0, 0))
	META:GetSet("Texture", nil)
	META:EndStorable()

	function META:SetColor(c)
		if type(c) == "string" then
			self.Color = Color.FromHex(c)
		else
			self.Color = c
		end
	end

	function META:DrawShadow()
		if not self.Shadows then return end

		render2d.PushMatrix()
		render2d.SetWorldMatrix(self:GetWorldMatrix())
		local s = self.Size + self.DrawSizeOffset
		render2d.SetBlendMode("alpha")
		render2d.SetColor(self.ShadowColor:Unpack())
		gfx.DrawShadow(self.ShadowOffset.x, self.ShadowOffset.y, s.x, s.y, self.ShadowSize, self.BorderRadius)
		render2d.PopMatrix()
	end

	function META:Draw()
		self:CalcAnimations()
		self:CalcResizing()

		if self.CalcLayout then self:CalcLayout() end

		if not self.Visible then return end

		self:DrawShadow()
		local clipping = self:GetClipping()

		if clipping then
			render2d.PushStencilMask()
			render2d.PushMatrix()
			render2d.SetWorldMatrix(self:GetWorldMatrix())
			render2d.DrawRect(0, 0, self.Size.x, self.Size.y)
			render2d.PopMatrix()
			render2d.BeginStencilTest()
		end

		render2d.PushMatrix()
		render2d.SetWorldMatrix(self:GetWorldMatrix())
		self:OnDraw()

		for _, child in ipairs(self:GetChildren()) do
			child:Draw()
		end

		if clipping then render2d.PopStencilMask() end

		self:OnPostDraw()
		render2d.PopMatrix()
	end

	function META:GetVisibleChildren()
		local tbl = {}

		for _, v in ipairs(self:GetChildren()) do
			if v.Visible then list.insert(tbl, v) end
		end

		return tbl
	end

	function META:OnPostDraw() end

	function META:OnDraw()
		local s = self.Size + self.DrawSizeOffset
		render2d.SetTexture(self.Texture)
		local c = self.Color + self.DrawColor
		render2d.SetColor(c.r, c.g, c.b, c.a * self.DrawAlpha)
		--render2d.DrawRect(0, 0, s.x, s.y)
		gfx.DrawRoundedRect(0, 0, s.x, s.y, self.BorderRadius)
		render2d.SetColor(0, 0, 0, 1)
	end
end
