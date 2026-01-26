local render2d = require("render2d.render2d")
local Vec2 = require("structs.vec2")
local Color = require("structs.color")
local Ang3 = require("structs.ang3")
local window = require("window")
local lsx = require("ecs.lsx_ecs")
local Texture = require("render.texture")
local glow_highlight_tex = Texture.New({
	width = 256,
	height = 256,
	format = "r8g8b8a8_unorm",
})
glow_highlight_tex:Shade([[
	float dist = distance(uv, vec2(0.5));
	return vec4(1.0, 1.0, 1.0, 1.0 - smoothstep(0.0, 0.5, dist));
]])
return function(props)
	local ref = lsx:UseRef(nil)
	local is_hovered = lsx:UseHover(ref)
	local is_pressed, set_pressed = lsx:UseState(false)
	local mouse_pos = lsx:UseMouse()
	local hover_ref = lsx:UseRef(nil)
	local press_ref = lsx:UseRef(nil)
	lsx:UseAnimate(
		hover_ref,
		{
			var = "DrawAlpha",
			to = is_hovered and 1 or 0,
			interpolation = "inOutSine",
			time = 0.25,
		},
		{is_hovered}
	)
	lsx:UseAnimate(
		press_ref,
		{
			var = "DrawScaleOffset",
			to = is_pressed and (Vec2() + 1) or (Vec2() + 0),
			interpolation = "inOutSine",
			time = 0.25,
			operator = "=",
		},
		{is_pressed}
	)
	lsx:UseAnimate(
		ref,
		{
			var = "DrawScaleOffset",
			to = is_pressed and (Vec2() + 0.95) or (Vec2() + 1),
			operator = "=",
			interpolation = {
				type = "spring",
				bounce = 0.6,
				duration = 150,
			},
		},
		{is_pressed}
	)
	lsx:UseAnimate(
		ref,
		{
			var = "DrawAngleOffset",
			-- The ternary is much snappier than the segmented approach
			to = not is_pressed and
				Ang3(0, 0, 0) or
				lsx:Value(function(self)
					if not self:IsHoveredExclusively() then return Ang3(0, 0, 0) end

					local mpos = window.GetMousePosition()
					local local_pos = self:GlobalToLocal(mpos)
					local size = self:GetSize()
					local nx = (local_pos.x / size.x) * 2 - 1
					local ny = (local_pos.y / size.y) * 2 - 1
					return Ang3(-ny, nx, 0) * 0.1
				end),
			interpolation = {
				type = "spring",
				bounce = 0.6,
				duration = 150,
			},
			time = 10,
		},
		{is_pressed}
	)
	local local_mouse = Vec2(0, 0)

	if ref.current then local_mouse = ref.current:GlobalToLocal(mouse_pos) end

	return lsx:Panel(
		{
			Name = "interactive test",
			ref = ref,
			Position = Vec2(100, 100),
			Size = Vec2(200, 50),
			Perspective = 400,
			Shadows = true,
			BorderRadius = 10,
			ShadowSize = 10,
			ShadowColor = Color(0, 0, 0, 0.2),
			ShadowOffset = Vec2(2, 2),
			Clipping = true,
			Color = Color(0.8, 0.2, 0.2, 1),
			OnMouseInput = function(self, button, press, local_pos)
				if button == "button_1" then
					set_pressed(press)
					return true
				end
			end,
			props,
			lsx:Panel(
				{
					Name = "large glow",
					ref = hover_ref,
					Position = local_mouse - Vec2(128, 128),
					OnDraw = function(self)
						if (self.DrawAlpha or 0) <= 0 then return end

						-- old draw 
						render2d.SetBlendMode("additive")
						render2d.SetTexture(self.Texture)
						local c = self.Color + (self.DrawColor or Color(0, 0, 0, 0))
						render2d.SetColor(c.r, c.g, c.b, c.a * (self.DrawAlpha or 0))
						local s = self.Size + (self.DrawSizeOffset or Vec2(0, 0))
						render2d.DrawRect(0, 0, s.x, s.y)
						render2d.SetBlendMode("alpha")
					end,
					Texture = glow_highlight_tex,
					Size = Vec2() + 256,
					Scale = Vec2() + 1.5,
					Color = Color(1, 1, 1, 0.15),
					IgnoreMouseInput = true,
				}
			),
			lsx:Panel(
				{
					Name = "small glow",
					ref = press_ref,
					Position = local_mouse - Vec2(128, 128),
					OnDraw = function(self)
						-- old draw 
						render2d.SetBlendMode("additive")
						render2d.SetTexture(self.Texture)
						local c = self.Color + (self.DrawColor or Color(0, 0, 0, 0))
						render2d.SetColor(c.r, c.g, c.b, c.a * (self.DrawAlpha or 1))
						local s = self.Size + (self.DrawSizeOffset or Vec2(0, 0))
						render2d.DrawRect(0, 0, s.x, s.y)
						render2d.SetBlendMode("alpha")
					end,
					Texture = glow_highlight_tex,
					Size = Vec2() + 256,
					Scale = Vec2() + 0.25,
					Color = Color(1, 1, 1, 0.5),
					IgnoreMouseInput = true,
				}
			),
		}
	)
end
