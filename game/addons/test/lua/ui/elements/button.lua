local render2d = require("render2d.render2d")
local Vec2 = require("structs.vec2")
local Color = require("structs.color")
local Ang3 = require("structs.ang3")
local window = require("window")
local Panel = require("ecs.entities.2d.panel")
local Texture = require("render.texture")
local theme = runfile("lua/ui/theme.lua")
return function(props)
	local is_disabled = props.Disabled
	local ent
	ent = Panel(
		{
			Name = "button",
			Size = props.Size or Vec2(200, 50),
			Layout = props.Layout,
			Perspective = 400,
			Shadows = false,
			BorderRadius = 10,
			ShadowSize = 10,
			ShadowColor = theme.Colors.ButtonShadow,
			ShadowOffset = Vec2(2, 2),
			Clipping = true,
			Cursor = is_disabled and "arrow" or "hand",
			Color = is_disabled and theme.Colors.ButtonDisabled or theme.Colors.ButtonNormal,
			DrawScaleOffset = Vec2(1, 1),
			DrawAngleOffset = Ang3(0, 0, 0),
			Children = props.Children or {},
			-- this event comes from the clickable componment and is "fired" on the entity itself
			OnClick = not is_disabled and
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
					if is_disabled then return end

					if button == "button_1" then
						ent.button_state.is_pressed = press
						theme.UpdateButtonAnimations(ent, ent.button_state)
						return true
					end
				end,
			},
			OnHover = function(self, hovered)
				ent.button_state.is_hovered = hovered
				theme.UpdateButtonAnimations(ent, ent.button_state)
			end,
			rect = {
				OnDraw = function() end,
			},
			gui_element = {
				OnDraw = function(self)
					theme.DrawButton(self, ent.button_state)
				end,
				OnPostDraw = function(self)
					theme.DrawButtonPost(self, ent.button_state)
				end,
				DrawAlpha = is_disabled and 0.5 or 1,
			},
		}
	)
	ent.button_state = {
		press_scale = 0,
		glow_alpha = 0,
		last_hovered = false,
		last_active = false,
		last_tilting = false,
		is_pressed = false,
		is_hovered = false,
		is_disabled = is_disabled,
		active_prop = props.Active,
	}
	return ent
end
