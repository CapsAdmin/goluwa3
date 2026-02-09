local render2d = require("render2d.render2d")
local Vec2 = require("structs.vec2")
local Rect = require("structs.rect")
local Color = require("structs.color")
local Ang3 = require("structs.ang3")
local window = require("window")
local Panel = require("ecs.panel")
local Texture = require("render.texture")
local theme = require("ui.theme")
return function(props)
	local state = {
		press_scale = 0,
		glow_alpha = 0,
		last_hovered = false,
		last_active = false,
		last_tilting = false,
		is_pressed = false,
		is_hovered = false,
		is_disabled = props.Disabled,
		active_prop = props.Active,
	}
	return Panel.NewPanel(
		{
			Name = "button",
			Size = props.Size or Vec2(200, 50),
			layout = props.layout,
			Perspective = 400,
			Shadows = false,
			BorderRadius = 10,
			ShadowSize = 10,
			ShadowColor = theme.GetColor("button_shadow"),
			ShadowOffset = Vec2(2, 2),
			Padding = Rect() + theme.GetPadding("XXS"),
			Clipping = true,
			Cursor = props.Disabled and "arrow" or "hand",
			Color = props.Disabled and
				theme.GetColor("button_disabled") or
				props.Color or
				theme.GetColor("primary"),
			DrawScaleOffset = Vec2(1, 1),
			DrawAngleOffset = Ang3(0, 0, 0),
			-- this event comes from the clickable componment and is "fired" on the entity itself
			OnClick = not props.Disabled and
				(
					props.OnClick or
					function()
						print("clicked!")
					end
				)
				or
				nil,
			mouse_input = {
				OnMouseInput = function(self, button, press, local_pos)
					if props.Disabled then return end

					if button == "button_1" then
						state.is_pressed = press
						theme.UpdateButtonAnimations(self.Owner, state)
						return true
					end
				end,
			},
			OnHover = function(self, hovered)
				state.is_hovered = hovered
				theme.UpdateButtonAnimations(self, state)
			end,
			rect = {
				OnDraw = function() end,
			},
			gui_element = {
				OnDraw = function(self)
					theme.DrawButton(self, state)
				end,
				OnPostDraw = function(self)
					theme.DrawButtonPost(self, state)
				end,
				DrawAlpha = props.Disabled and 0.5 or 1,
			},
		}
	)
end
