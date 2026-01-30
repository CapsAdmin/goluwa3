local render2d = require("render2d.render2d")
local Vec2 = require("structs.vec2")
local Color = require("structs.color")
local Ang3 = require("structs.ang3")
local window = require("window")
local lsx = require("ecs.lsx_ecs")
local prototype = require("prototype")
local fonts = require("render2d.fonts")
local render2d = require("render2d.render2d")
local Color = require("structs.color")
local Vec2 = require("structs.vec2")
local gfx = require("render2d.gfx")
local glow_linear_tex = require("render.textures.glow_linear")
local glow_point_tex = require("render.textures.glow_point")
local gradient_tex = require("render.textures.gradient_linear")

local function line(x1, y1, x2, y2, thickness, tex)
	if tex == false then
		render2d.SetTexture(nil)
	else
		render2d.SetTexture(tex or glow_linear_tex)
	end

	render2d.PushMatrix()
	local angle = math.atan2(y2 - y1, x2 - x1)
	local length = math.sqrt((x2 - x1) ^ 2 + (y2 - y1) ^ 2)
	render2d.Translate(x1, y1)
	render2d.Rotate(angle)
	render2d.DrawRect(0, -thickness / 2, length, thickness)
	render2d.PopMatrix()
end

local function rect(x, y, w, h, thickness, extent, tex)
	extent = extent or 0
	line(x - extent, y, x + w + extent, y, thickness, tex)
	line(x + w, y - extent, x + w, y + h + extent, thickness, tex)
	line(x + w + extent, y + h, x - extent, y + h, thickness, tex)
	line(x, y + h + extent, x, y - extent, thickness, tex)
end

local function edge_decor(x, y)
	render2d.PushMatrix()
	render2d.Translate(x, y)
	render2d.Rotate(45)
	local size = 3
	render2d.SetEdgeFeather(0.5)
	rect(-size, -size, size * 2, size * 2, 2, 0, false)
	render2d.SetEdgeFeather(0)
	render2d.PopMatrix()
	render2d.SetTexture(glow_point_tex)
	render2d.SetBlendMode("additive")
	render2d.PushColor(0.1, 0.6, 1, 0.25)
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

local function OnDraw(self)
	local s = self.Entity.transform_2d.Size + self.Entity.transform_2d.DrawSizeOffset
	local c = self.Entity.rect_2d.Color + self.Entity.rect_2d.DrawColor
	render2d.SetColor(c.r, c.g, c.b, c.a * self.Entity.rect_2d.DrawAlpha)
	render2d.SetBlendMode("alpha")
	render2d.PushUV()
	render2d.SetUV2(0.5, 0.1, 0.7, 0.6)
	render2d.SetTexture(glow_linear_tex)
	render2d.DrawRect(0, 0, s.x, s.y)
	render2d.PopUV()
end

local function OnPostDraw(self)
	local s = self.Entity.transform_2d.Size + self.Entity.transform_2d.DrawSizeOffset
	local c = self.Entity.rect_2d.Color + self.Entity.rect_2d.DrawColor

	do
		render2d.SetColor(0.106, 0.463, 0.678, c.a * self.Entity.rect_2d.DrawAlpha)
		render2d.SetBlendMode("alpha")
		rect(-4, -4, s.x + 8, s.y + 8, 3, 40)
		edge_decor(-4, -4)
		edge_decor(s.x + 4, -4)
		edge_decor(s.x + 4, s.y + 4)
		edge_decor(-4, s.y + 4)
	end
end

return function(props)
	return lsx:Panel(
		lsx:MergeProps(
			{
				Name = "frame",
				Color = Color.FromHex("#062a67"):SetAlpha(0.9),
				DragEnabled = true,
				gui_element_2d = {
					OnDraw = OnDraw,
					OnPostDraw = OnPostDraw,
				},
			},
			props
		)
	)
end
