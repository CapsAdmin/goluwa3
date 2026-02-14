local Vec2 = require("structs.vec2")
local Color = require("structs.color")
local Rect = require("structs.rect")
local Panel = require("ecs.panel")
local theme = require("ui.theme")
local Text = require("ui.elements.text")
return function(props)
	local state = {
		value = props.Value or false,
		is_hovered = false,
		glow_alpha = 0,
		check_anim = props.Value and 1 or 0,
		last_hovered = false,
		last_value = props.Value or false,
	}
	return Panel.New(
		{
			Name = "checkbox_graphic",
			OnSetProperty = theme.OnSetProperty,
			transform = {
				Size = props.Size or "M",
			},
			layout = {
				props.layout,
			},
			mouse_input = {
				Cursor = "hand",
				OnMouseInput = function(self, button, press, local_pos)
					if button == "button_1" and press then
						state.value = not state.value

						if props.OnChange then props.OnChange(state.value) end

						theme.UpdateCheckboxAnimations(self.Owner, state)
						return true
					end
				end,
				OnHover = function(self, hovered)
					state.is_hovered = hovered
					theme.UpdateCheckboxAnimations(self.Owner, state)
				end,
			},
			gui_element = {
				OnDraw = function(self)
					theme.UpdateCheckboxAnimations(self.Owner, state)
					theme.panels.checkbox(self.Owner, state)
				end,
			},
			animation = true,
			clickable = true,
		}
	)
end
