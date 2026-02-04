local render2d = require("render2d.render2d")
local Vec2 = require("structs.vec2")
local Color = require("structs.color")
local Ang3 = require("structs.ang3")
local window = require("window")
local Panel = require("ecs.entities.2d.panel")
local Texture = require("render.texture")
local animations = require("animations")
local glow_linear_tex = require("render.textures.glow_linear")
local glow_point_tex = require("render.textures.glow_point")
local gradient_tex = require("render.textures.gradient_linear")

local function line(x1, y1, x2, y2, thickness, tex)
	render2d.SetTexture(tex or glow_linear_tex)
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

return function(props)
	local thickness = props.Size or 10
	return Panel(
		{
			Name = "MenuSpacer",
			Size = props.Vertical and Vec2(thickness, 0) or Vec2(0, thickness), -- 0 is assumed to get stretched out somehow
			Color = Color(0, 0, 0, 0),
			Layout = props.Layout,
			Stackable = true,
			gui_element = {
				OnDraw = function(self)
					local size = self.Owner.transform:GetSize()
					local w = size.x
					local h = size.y
					render2d.PushColor(1, 1, 1, 0.1)

					if props.Vertical then
						line(w / 2, 0, w / 2, h, 2, gradient_tex)
						edge_decor(w / 2, 0)
						edge_decor(w / 2, h)
					else
						line(0, h / 2, w, h / 2, 2, gradient_tex)
						edge_decor(0, h / 2)
						edge_decor(w, h / 2)
					end

					render2d.PopColor()
				end,
			},
		}
	)
end
