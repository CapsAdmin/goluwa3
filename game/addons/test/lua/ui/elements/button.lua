local render2d = require("render2d.render2d")
local Vec2 = require("structs.vec2")
local Color = require("structs.color")
local Ang3 = require("structs.ang3")
local window = require("window")
local lsx = require("ecs.lsx_ecs")
local Texture = require("render.texture")
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
	local ref = lsx:UseRef(nil)
	local is_hovered = lsx:UseHoverExclusively(ref)
	local is_pressed, set_pressed = lsx:UseState(false)
	local is_disabled = props.Disabled
	local is_active = not is_disabled and ((is_hovered and is_pressed) or props.Active)
	local glow_alpha_ref = lsx:UseRef(0)
	local press_scale_ref = lsx:UseRef(0)
	lsx:UseAnimate(
		ref,
		{
			var = "GlowAlpha",
			get = function()
				return glow_alpha_ref.current
			end,
			set = function(_, val)
				glow_alpha_ref.current = val
			end,
			to = (is_hovered and not is_disabled) and 1 or 0,
			interpolation = "inOutSine",
			time = 0.25,
		},
		{is_hovered, is_disabled}
	)
	lsx:UseAnimate(
		ref,
		{
			var = "PressScale",
			get = function()
				return press_scale_ref.current
			end,
			set = function(_, val)
				press_scale_ref.current = val
			end,
			to = is_active and 1 or 0,
			interpolation = (is_pressed and not is_hovered) and "linear" or "inOutSine",
			time = (is_pressed and not is_hovered) and 0.3 or 0.25,
		},
		{is_pressed, is_hovered, is_active}
	)
	lsx:UseAnimate(
		ref,
		{
			var = "DrawScaleOffset",
			to = is_active and (Vec2() + 0.95) or (Vec2() + 1),
			operator = "=",
			interpolation = (
					is_pressed and
					not is_hovered
				)
				and
				"linear" or
				{
					type = "spring",
					bounce = 0.6,
					duration = 150,
				},
			time = (is_pressed and not is_hovered) and 0.3 or nil,
		},
		{is_pressed, is_hovered, is_active}
	)
	lsx:UseAnimate(
		ref,
		{
			var = "DrawAngleOffset",
			-- The ternary is much snappier than the segmented approach
			to = not is_active and
				Ang3(0, 0, 0) or
				lsx:Value(function(self)
					local mpos = window.GetMousePosition()
					local local_pos = self:GlobalToLocal(mpos)
					local size = self:GetSize()
					local nx = (local_pos.x / size.x) * 2 - 1
					local ny = (local_pos.y / size.y) * 2 - 1
					return Ang3(-ny, nx, 0) * 0.1
				end),
			interpolation = (
					is_pressed and
					not is_hovered
				)
				and
				"linear" or
				{
					type = "spring",
					bounce = 0.6,
					duration = 150,
				},
			time = (is_pressed and not is_hovered) and 0.3 or 10,
		},
		{is_pressed, is_hovered, is_active}
	)
	return lsx:Panel(
		lsx:MergeProps(
			{
				Name = "button",
				ref = ref,
				Position = props.Position or (not props.Layout and Vec2(100, 100) or nil),
				Size = props.Size or Vec2(200, 50),
				Perspective = 400,
				Shadows = false,
				Resizable = false,
				BorderRadius = 10,
				ShadowSize = 10,
				ShadowColor = Color(0, 0, 0, 0.2),
				ShadowOffset = Vec2(2, 2),
				Clipping = true,
				Cursor = is_disabled and "arrow" or "hand",
				Color = is_disabled and Color(0.3, 0.3, 0.3, 1) or Color(0.8, 0.8, 0.2, 1),
				OnClick = not is_disabled and (props.OnClick or function()
					print("clicked!")
				end) or nil,
				OnMouseInput = function(self, button, press, local_pos)
					if is_disabled then return end
					if button == "button_1" then
						set_pressed(press)
						return true
					end
				end,
				rect_2d = {
					OnPreDraw = function() end,
					OnDraw = function() end,
				},
				gui_element_2d = {
					OnDraw = function(self)
						local size = self.Entity.transform_2d.Size
						local glow_alpha = glow_alpha_ref.current
						render2d.PushUV()
						render2d.SetUV2(0, 0, 0.5, 1)
						render2d.SetTexture(gradient_tex)
						render2d.SetColor(0, 0.40 * glow_alpha, 0.70 * glow_alpha, 1)
						render2d.DrawRect(0, 0, size.x, size.y)
						render2d.PopUV()
						local mpos = window.GetMousePosition()

						if not is_disabled and self.Entity.mouse_input_2d:IsHoveredExclusively(mpos) then
							local lpos = self.Entity.transform_2d:GlobalToLocal(mpos)
							render2d.SetBlendMode("additive")
							render2d.SetTexture(glow_linear_tex)

							if glow_alpha > 0 then
								render2d.SetColor(1, 1, 1, 0.15 * glow_alpha)
								local s = 256 * 1.5
								render2d.DrawRect(lpos.x - s / 2, lpos.y - s / 2, s, s)
							end

							render2d.SetTexture(glow_point_tex)
							local press_scale = press_scale_ref.current
							render2d.SetColor(1, 1, 1, 0.5 * press_scale)
							local s = press_scale * 150
							render2d.DrawRect(lpos.x - s / 2, lpos.y - s / 2, s, s)
							render2d.SetBlendMode("alpha")
						end
					end,
					OnPostDraw = function(self)
						local glow_alpha = glow_alpha_ref.current
						local size = self.Entity.transform_2d.Size
						render2d.SetBlendMode("additive")
						render2d.SetColor(glow_alpha, glow_alpha, glow_alpha, 1)
						render2d.SetTexture(glow_linear_tex)
						render2d.PushUV()
						render2d.SetUV2(0.2, 0, 0.8, 1)
						line(-2, 0, -2, size.y, 4)
						render2d.PopUV()
						render2d.SetColor(0.35, 0.71, 0.816, glow_alpha)
						render2d.PushUV()
						render2d.SetUV2(0.5, 0, 1, 0.5)
						line(0, 0, size.x, 0, 1, glow_linear_tex)
						line(0, size.y, size.x, size.y, 1, glow_linear_tex)
						render2d.PopUV()
						render2d.SetBlendMode("alpha")
					end,
					DrawAlpha = is_disabled and 0.5 or 1,
				},
			},
			props
		)
	)
end
