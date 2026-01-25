local prototype = require("prototype")
local fonts = require("render2d.fonts")
local render2d = require("render2d.render2d")
local Color = require("structs.color")
local Vec2 = require("structs.vec2")
local gfx = require("render2d.gfx")
local META = prototype.CreateTemplate("panel_frame")
META.Base = require("gui.panels.base")
local glow_linear_tex
local glow_point_tex
local gradient_tex

function META:Initialize()
	self.BaseClass.Initialize(self)
	glow_linear_tex = require("render.textures.glow_linear")
	glow_point_tex = require("render.textures.glow_point")
	gradient_tex = require("render.textures.gradient_linear")
end

local function line(x1, y1, x2, y2, thickness)
	render2d.SetTexture(glow_linear_tex)
	render2d.PushMatrix()
	local angle = math.atan2(y2 - y1, x2 - x1)
	local length = math.sqrt((x2 - x1) ^ 2 + (y2 - y1) ^ 2)
	render2d.Translate(x1, y1)
	render2d.Rotate(angle)
	render2d.DrawRect(0, -thickness / 2, length, thickness)
	render2d.PopMatrix()
end

local function rect(x, y, w, h, thickness, extent)
	extent = extent or 0
	line(x - extent, y, x + w + extent, y, thickness)
	line(x + w, y - extent, x + w, y + h + extent, thickness)
	line(x + w + extent, y + h, x - extent, y + h, thickness)
	line(x, y + h + extent, x, y - extent, thickness)
end

local function edge_decor(x, y)
	render2d.PushMatrix()
	render2d.Translate(x, y)
	render2d.Rotate(45)
	local size = 3
	rect(-size, -size, size * 2, size * 2, 2, 2)
	render2d.PopMatrix()
	render2d.SetTexture(glow_point_tex)
	render2d.SetBlendMode("additive")
	render2d.PushColor(1, 1, 1, 0.1)
	local size = size * 40
	render2d.DrawRect(x - size, y - size, size * 2, size * 2)
	render2d.PopColor()

	do
		render2d.PushColor(1, 1, 1, 1)
		local size = 4
		render2d.SetTexture(glow_point_tex)
		render2d.DrawRect(x - size, y - size, size * 2, size * 2)
		render2d.SetBlendMode("alpha")
		render2d.PopColor()
	end
end

function META:OnDraw()
	local s = self.Size + self.DrawSizeOffset
	local c = self.Color + self.DrawColor
	render2d.SetColor(c.r, c.g, c.b, c.a * self.DrawAlpha)
	render2d.SetBlendMode("alpha")
	render2d.PushUV()
	render2d.SetUV2(0.5, 0.1, 0.7, 0.6)
	render2d.SetTexture(glow_linear_tex)
	render2d.DrawRect(0, 0, s.x, s.y)
	render2d.PopUV()
end

function META:OnPostDraw()
	local s = self.Size + self.DrawSizeOffset
	local c = self.Color + self.DrawColor

	do
		render2d.SetColor(c.r, c.g, c.b, c.a * self.DrawAlpha)
		render2d.SetBlendMode("alpha")
		rect(-4, -4, s.x + 8, s.y + 8, 3, 40)
		edge_decor(-4, -4)
		edge_decor(s.x + 4, -4)
		edge_decor(s.x + 4, s.y + 4)
		edge_decor(-4, s.y + 4)
	end
end

if HOTRELOAD then
	local timer = require("timer")
	local utility = require("utility")

	timer.Delay(0, function()
		local gui = require("gui.gui")
		local pnl = utility.RemoveOldObject(gui.Create("panel_frame"))
		pnl:SetPosition(Vec2() + 300)
		pnl:SetSize(Vec2() + 200)
		pnl:SetDragEnabled(true)
		pnl:SetColor(Color.FromHex("#062a67"):SetAlpha(1))
	end)
end

return META:Register()
