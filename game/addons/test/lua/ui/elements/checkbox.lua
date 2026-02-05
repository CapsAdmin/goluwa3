local Vec2 = require("structs.vec2")
local Color = require("structs.color")
local Rect = require("structs.rect")
local Panel = require("ecs.panel")
local theme = runfile("lua/ui/theme.lua")
local Text = runfile("lua/ui/elements/text.lua")
return function(props)
	local ent
	local state = {
		value = props.Value or false,
		is_hovered = false,
		glow_alpha = 0,
		check_anim = props.Value and 1 or 0,
		last_hovered = false,
		last_value = props.Value or false,
	}
	ent = Panel.NewPanel(
		{
			Name = "checkbox_graphic",
			Size = props.Size or Vec2(theme.Sizes.CheckboxSize, theme.Sizes.CheckboxSize),
			Layout = props.Layout,
			Cursor = "hand",
			Color = Color(0, 0, 0, 0),
			mouse_input = {
				OnMouseInput = function(self, button, press, local_pos)
					if button == "button_1" and press then
						state.value = not state.value

						if props.OnChange then props.OnChange(state.value) end

						theme.UpdateCheckboxAnimations(ent, state)
						return true
					end
				end,
			},
			OnHover = function(self, hovered)
				state.is_hovered = hovered
				theme.UpdateCheckboxAnimations(ent, state)
			end,
			gui_element = {
				OnDraw = function(self)
					theme.UpdateCheckboxAnimations(ent, state)
					theme.DrawCheckbox(self, state)
				end,
			},
		}
	)
	return ent
end
